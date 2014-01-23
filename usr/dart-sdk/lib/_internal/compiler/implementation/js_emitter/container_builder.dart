// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart2js.js_emitter;

/// This class should morph into something that makes it easy to build
/// JavaScript representations of libraries, class-sides, and instance-sides.
/// Initially, it is just a placeholder for code that is moved from
/// [CodeEmitterTask].
class ContainerBuilder extends CodeEmitterHelper {
  final Map<Element, Element> staticGetters = new Map<Element, Element>();

  /// A cache of synthesized closures for top-level, static or
  /// instance methods.
  final Map<String, Element> methodClosures = <String, Element>{};

  /**
   * Generate stubs to handle invocation of methods with optional
   * arguments.
   *
   * A method like [: foo([x]) :] may be invoked by the following
   * calls: [: foo(), foo(1), foo(x: 1) :]. See the sources of this
   * function for detailed examples.
   */
  void addParameterStub(FunctionElement member,
                        Selector selector,
                        AddStubFunction addStub,
                        Set<String> alreadyGenerated) {
    FunctionSignature parameters = member.computeSignature(compiler);
    int positionalArgumentCount = selector.positionalArgumentCount;
    if (positionalArgumentCount == parameters.parameterCount) {
      assert(selector.namedArgumentCount == 0);
      return;
    }
    if (parameters.optionalParametersAreNamed
        && selector.namedArgumentCount == parameters.optionalParameterCount) {
      // If the selector has the same number of named arguments as the element,
      // we don't need to add a stub. The call site will hit the method
      // directly.
      return;
    }
    ConstantHandler handler = compiler.constantHandler;
    List<String> names = selector.getOrderedNamedArguments();

    String invocationName = namer.invocationName(selector);
    if (alreadyGenerated.contains(invocationName)) return;
    alreadyGenerated.add(invocationName);

    bool isInterceptedMethod = backend.isInterceptedMethod(member);

    // If the method is intercepted, we need to also pass the actual receiver.
    int extraArgumentCount = isInterceptedMethod ? 1 : 0;
    // Use '$receiver' to avoid clashes with other parameter names. Using
    // '$receiver' works because [:namer.safeName:] used for getting parameter
    // names never returns a name beginning with a single '$'.
    String receiverArgumentName = r'$receiver';

    // The parameters that this stub takes.
    List<jsAst.Parameter> parametersBuffer =
        new List<jsAst.Parameter>(selector.argumentCount + extraArgumentCount);
    // The arguments that will be passed to the real method.
    List<jsAst.Expression> argumentsBuffer =
        new List<jsAst.Expression>(
            parameters.parameterCount + extraArgumentCount);

    int count = 0;
    if (isInterceptedMethod) {
      count++;
      parametersBuffer[0] = new jsAst.Parameter(receiverArgumentName);
      argumentsBuffer[0] = js(receiverArgumentName);
      task.interceptorEmitter.interceptorInvocationNames.add(invocationName);
    }

    int optionalParameterStart = positionalArgumentCount + extraArgumentCount;
    // Includes extra receiver argument when using interceptor convention
    int indexOfLastOptionalArgumentInParameters = optionalParameterStart - 1;

    TreeElements elements =
        compiler.enqueuer.resolution.getCachedElements(member);

    int parameterIndex = 0;
    parameters.orderedForEachParameter((Element element) {
      String jsName = backend.namer.safeName(element.name);
      assert(jsName != receiverArgumentName);
      if (count < optionalParameterStart) {
        parametersBuffer[count] = new jsAst.Parameter(jsName);
        argumentsBuffer[count] = js(jsName);
      } else {
        int index = names.indexOf(element.name);
        if (index != -1) {
          indexOfLastOptionalArgumentInParameters = count;
          // The order of the named arguments is not the same as the
          // one in the real method (which is in Dart source order).
          argumentsBuffer[count] = js(jsName);
          parametersBuffer[optionalParameterStart + index] =
              new jsAst.Parameter(jsName);
        } else {
          Constant value = handler.initialVariableValues[element];
          if (value == null) {
            argumentsBuffer[count] = task.constantReference(new NullConstant());
          } else {
            if (!value.isNull()) {
              // If the value is the null constant, we should not pass it
              // down to the native method.
              indexOfLastOptionalArgumentInParameters = count;
            }
            argumentsBuffer[count] = task.constantReference(value);
          }
        }
      }
      count++;
    });

    List body;
    if (member.hasFixedBackendName()) {
      body = task.nativeEmitter.generateParameterStubStatements(
          member, isInterceptedMethod, invocationName,
          parametersBuffer, argumentsBuffer,
          indexOfLastOptionalArgumentInParameters);
    } else if (member.isInstanceMember()) {
      body = [js.return_(
          js('this')[namer.getNameOfInstanceMember(member)](argumentsBuffer))];
    } else {
      body = [js.return_(namer.elementAccess(member)(argumentsBuffer))];
    }

    jsAst.Fun function = js.fun(parametersBuffer, body);

    addStub(selector, function);
  }

  void addParameterStubs(FunctionElement member, AddStubFunction defineStub,
                         [bool canTearOff = false]) {
    if (member.enclosingElement.isClosure()) {
      ClosureClassElement cls = member.enclosingElement;
      if (cls.supertype.element == compiler.boundClosureClass) {
        compiler.internalErrorOnElement(cls.methodElement, 'Bound closure1.');
      }
      if (cls.methodElement.isInstanceMember()) {
        compiler.internalErrorOnElement(cls.methodElement, 'Bound closure2.');
      }
    }

    // We fill the lists depending on the selector. For example,
    // take method foo:
    //    foo(a, b, {c, d});
    //
    // We may have multiple ways of calling foo:
    // (1) foo(1, 2);
    // (2) foo(1, 2, c: 3);
    // (3) foo(1, 2, d: 4);
    // (4) foo(1, 2, c: 3, d: 4);
    // (5) foo(1, 2, d: 4, c: 3);
    //
    // What we generate at the call sites are:
    // (1) foo$2(1, 2);
    // (2) foo$3$c(1, 2, 3);
    // (3) foo$3$d(1, 2, 4);
    // (4) foo$4$c$d(1, 2, 3, 4);
    // (5) foo$4$c$d(1, 2, 3, 4);
    //
    // The stubs we generate are (expressed in Dart):
    // (1) foo$2(a, b) => foo$4$c$d(a, b, null, null)
    // (2) foo$3$c(a, b, c) => foo$4$c$d(a, b, c, null);
    // (3) foo$3$d(a, b, d) => foo$4$c$d(a, b, null, d);
    // (4) No stub generated, call is direct.
    // (5) No stub generated, call is direct.

    Set<Selector> selectors = member.isInstanceMember()
        ? compiler.codegenWorld.invokedNames[member.name]
        : null; // No stubs needed for static methods.

    /// Returns all closure call selectors renamed to match this member.
    Set<Selector> callSelectorsAsNamed() {
      if (!canTearOff) return null;
      Set<Selector> callSelectors = compiler.codegenWorld.invokedNames[
          namer.closureInvocationSelectorName];
      if (callSelectors == null) return null;
      return callSelectors.map((Selector callSelector) {
        return new Selector.call(
            member.name, member.getLibrary(),
            callSelector.argumentCount, callSelector.namedArguments);
      }).toSet();
    }
    if (selectors == null) {
      selectors = callSelectorsAsNamed();
      if (selectors == null) return;
    } else {
      Set<Selector> callSelectors = callSelectorsAsNamed();
      if (callSelectors != null) {
        selectors = selectors.union(callSelectors);
      }
    }
    Set<Selector> untypedSelectors = new Set<Selector>();
    if (selectors != null) {
      for (Selector selector in selectors) {
        if (!selector.appliesUnnamed(member, compiler)) continue;
        if (untypedSelectors.add(selector.asUntyped)) {
          // TODO(ahe): Is the last argument to [addParameterStub] needed?
          addParameterStub(member, selector, defineStub, new Set<String>());
        }
      }
    }
    if (canTearOff) {
      selectors = compiler.codegenWorld.invokedNames[
          namer.closureInvocationSelectorName];
      if (selectors != null) {
        for (Selector selector in selectors) {
          selector = new Selector.call(
              member.name, member.getLibrary(),
              selector.argumentCount, selector.namedArguments);
          if (!selector.appliesUnnamed(member, compiler)) continue;
          if (untypedSelectors.add(selector)) {
            // TODO(ahe): Is the last argument to [addParameterStub] needed?
            addParameterStub(member, selector, defineStub, new Set<String>());
          }
        }
      }
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void emitCallStubForGetter(Element member,
                             Set<Selector> selectors,
                             AddPropertyFunction addProperty) {
    assert(invariant(member, member.isDeclaration));
    LibraryElement memberLibrary = member.getLibrary();
    // If the method is intercepted, the stub gets the
    // receiver explicitely and we need to pass it to the getter call.
    bool isInterceptedMethod = backend.isInterceptedMethod(member);

    const String receiverArgumentName = r'$receiver';

    jsAst.Expression buildGetter() {
      if (member.isGetter()) {
        String getterName = namer.getterName(member);
        return js('this')[getterName](
            isInterceptedMethod
                ? <jsAst.Expression>[js(receiverArgumentName)]
                : <jsAst.Expression>[]);
      } else {
        String fieldName = namer.instanceFieldPropertyName(member);
        return js('this')[fieldName];
      }
    }

    // Two selectors may match but differ only in type.  To avoid generating
    // identical stubs for each we track untyped selectors which already have
    // stubs.
    Set<Selector> generatedSelectors = new Set<Selector>();
    for (Selector selector in selectors) {
      if (selector.applies(member, compiler)) {
        selector = selector.asUntyped;
        if (generatedSelectors.contains(selector)) continue;
        generatedSelectors.add(selector);

        String invocationName = namer.invocationName(selector);
        Selector callSelector = new Selector.callClosureFrom(selector);
        String closureCallName = namer.invocationName(callSelector);

        List<jsAst.Parameter> parameters = <jsAst.Parameter>[];
        List<jsAst.Expression> arguments = <jsAst.Expression>[];
        if (isInterceptedMethod) {
          parameters.add(new jsAst.Parameter(receiverArgumentName));
        }

        for (int i = 0; i < selector.argumentCount; i++) {
          String name = 'arg$i';
          parameters.add(new jsAst.Parameter(name));
          arguments.add(js(name));
        }

        jsAst.Fun function = js.fun(
            parameters,
            js.return_(buildGetter()[closureCallName](arguments)));

        addProperty(invocationName, function);
      }
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void emitExtraAccessors(Element member, ClassBuilder builder) {
    assert(invariant(member, member.isDeclaration));
    if (member.isGetter() || member.isField()) {
      Set<Selector> selectors = compiler.codegenWorld.invokedNames[member.name];
      if (selectors != null && !selectors.isEmpty) {
        emitCallStubForGetter(member, selectors, builder.addProperty);
      }
    }
  }

  void addMember(Element member, ClassBuilder builder) {
    assert(invariant(member, member.isDeclaration));

    if (member.isField()) {
      addMemberField(member, builder);
    } else if (member.isFunction() ||
               member.isGenerativeConstructorBody() ||
               member.isGenerativeConstructor() ||
               member.isAccessor()) {
      addMemberMethod(member, builder);
    } else {
      compiler.internalErrorOnElement(
          member, 'unexpected kind: "${member.kind}"');
    }
    if (member.isInstanceMember()) emitExtraAccessors(member, builder);
  }

  void addMemberMethod(FunctionElement member, ClassBuilder builder) {
    if (member.isAbstract) return;
    jsAst.Expression code = backend.generatedCode[member];
    if (code == null) return;
    String name = namer.getNameOfMember(member);
    task.interceptorEmitter.recordMangledNameOfMemberMethod(member, name);
    FunctionSignature parameters = member.computeSignature(compiler);
    bool needsStubs = !parameters.optionalParameters.isEmpty;
    bool canTearOff = false;
    bool isClosure = false;
    bool canBeApplied = compiler.enabledFunctionApply;
    String tearOffName;
    if (!member.isFunction() || member.isConstructor() || member.isAccessor()) {
      canTearOff = false;
      canBeApplied = false;
    } else if (member.isInstanceMember()) {
      if (member.getEnclosingClass().isClosure()) {
        canTearOff = false;
        isClosure = true;
      } else {
        // Careful with operators.
        canTearOff = compiler.codegenWorld.hasInvokedGetter(member, compiler);
        tearOffName = namer.getterName(member);
      }
    } else {
      canTearOff =
          compiler.codegenWorld.staticFunctionsNeedingGetter.contains(member);
      tearOffName = namer.getStaticClosureName(member);
    }

    bool canBeReflected = backend.isAccessibleByReflection(member);
    bool needStructuredInfo =
        canTearOff || canBeReflected || canBeApplied;
    if (!needStructuredInfo) {
      builder.addProperty(name, code);
      if (needsStubs) {
        addParameterStubs(
            member,
            (Selector selector, jsAst.Fun function) {
              builder.addProperty(namer.invocationName(selector), function);
            });
      }
      return;
    }

    if (canTearOff) {
      assert(invariant(member, !member.isGenerativeConstructor()));
      assert(invariant(member, !member.isGenerativeConstructorBody()));
      assert(invariant(member, !member.isConstructor()));
    }

    // This element is needed for reflection or needs additional stubs. So we
    // need to retain additional information.

    // The information is stored in an array with this format:
    //
    // 1.   The JS function for this member.
    // 2.   First stub.
    // 3.   Name of first stub.
    // ...
    // M.   Call name of this member.
    // M+1. Call name of first stub.
    // ...
    // N.   Getter name for tearOff.
    // N+1. (Required parameter count << 1) + (member.isAccessor() ? 1 : 0).
    // N+2. (Optional parameter count << 1) +
    //                      (parameters.optionalParametersAreNamed ? 1 : 0).
    // N+3. Index to function type in constant pool.
    // N+4. First default argument.
    // ...
    // O.   First parameter name (if needed for reflection or Function.apply).
    // ...
    // P.   Unmangled name (if reflectable).
    // P+1. First metadata (if reflectable).
    // ...
    // TODO(ahe): Consider one of the parameter counts can be replaced by the
    // length property of the JavaScript function object.

    List expressions = [];

    String callSelectorString = 'null';
    if (member.isFunction()) {
      Selector callSelector =
          new Selector.fromElement(member, compiler).toCallSelector();
      callSelectorString = '"${namer.invocationName(callSelector)}"';
    }

    // On [requiredParameterCount], the lower bit is set if this method can be
    // called reflectively.
    int requiredParameterCount = parameters.requiredParameterCount << 1;
    if (member.isAccessor()) requiredParameterCount++;

    int optionalParameterCount = parameters.optionalParameterCount << 1;
    if (parameters.optionalParametersAreNamed) optionalParameterCount++;

    expressions.add(code);

    List tearOffInfo = [new jsAst.LiteralString(callSelectorString)];

    if (needsStubs || canTearOff) {
      addParameterStubs(member, (Selector selector, jsAst.Fun function) {
        expressions.add(function);
        if (member.isInstanceMember()) {
          Set invokedSelectors =
              compiler.codegenWorld.invokedNames[member.name];
          //if (invokedSelectors != null && invokedSelectors.contains(selector)) {
            expressions.add(js.string(namer.invocationName(selector)));
          //} else {
          //  // Don't add a stub for calling this as a regular instance method,
          //  // we only need the "call" stub for implicit closures of this
          //  // method.
          //  expressions.add("null");
          //}
        } else {
          // Static methods don't need "named" stubs as the default arguments
          // are inlined at call sites. But static methods might need "call"
          // stubs for implicit closures.
          expressions.add("null");
          // TOOD(ahe): Since we know when reading static data versus instance
          // data, we can eliminate this element.
        }
        Set<Selector> callSelectors = compiler.codegenWorld.invokedNames[
            namer.closureInvocationSelectorName];
        Selector callSelector = selector.toCallSelector();
        String callSelectorString = 'null';
        if (canTearOff && callSelectors != null &&
            callSelectors.contains(callSelector)) {
          callSelectorString = '"${namer.invocationName(callSelector)}"';
        }
        tearOffInfo.add(new jsAst.LiteralString(callSelectorString));
      }, canTearOff);
    }

    jsAst.Expression memberTypeExpression;
    if (canTearOff || canBeReflected) {
      DartType memberType;
      if (member.isGenerativeConstructorBody()) {
        var body = member;
        memberType = body.constructor.computeType(compiler);
      } else {
        memberType = member.computeType(compiler);
      }
      if (memberType.containsTypeVariables) {
        jsAst.Expression thisAccess = js(r'this.$receiver');
        memberTypeExpression =
            backend.rti.getSignatureEncoding(memberType, thisAccess);
      } else {
        memberTypeExpression =
            js.toExpression(task.metadataEmitter.reifyType(memberType));
      }
    } else {
      memberTypeExpression = js('null');
    }

    expressions
        ..addAll(tearOffInfo)
        ..add((tearOffName == null || member.isAccessor())
              ? js("null") : js.string(tearOffName))
        ..add(requiredParameterCount)
        ..add(optionalParameterCount)
        ..add(memberTypeExpression)
        ..addAll(task.metadataEmitter.reifyDefaultArguments(member));

    if (canBeReflected || canBeApplied) {
      parameters.orderedForEachParameter((Element parameter) {
        expressions.add(task.metadataEmitter.reifyName(parameter.name));
      });
    }
    if (canBeReflected) {
      jsAst.LiteralString reflectionName;
      if (member.isConstructor()) {
        String reflectionNameString = task.getReflectionName(member, name);
        reflectionName =
            new jsAst.LiteralString(
                '"new ${Elements.reconstructConstructorName(member)}"'
                ' /* $reflectionNameString */');
      } else {
        reflectionName = js.string(member.name);
      }
      expressions
          ..add(reflectionName)
          ..addAll(task.metadataEmitter.computeMetadata(member));
    } else if (isClosure && canBeApplied) {
      expressions.add(js.string(member.name));
    }

    builder.addProperty(name, js.toExpression(expressions));
  }

  void addMemberField(VariableElement member, ClassBuilder builder) {
    // For now, do nothing.
  }
}
