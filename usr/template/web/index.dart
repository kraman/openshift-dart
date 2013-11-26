import 'dart:html';
import 'dart:async';

void main() {
  String t = new DateTime.now().toString();
  querySelector("#sample_text_id").text = "The time is now: " + t + ".";
  new Timer.periodic(const Duration(seconds: 1), getTime);
}

void getTime(Timer timer) {
  String t = new DateTime.now().toString();
  querySelector("#sample_text_id").text = "The time is now: " + t + ".";
}
