# Keyboard UI harness

This isolated XCTest host exercises the installed keyboard extension in a text field. Use a **disposable iPhone 16e simulator in portrait**, with Chinese system settings, the simulator build of the main app installed, and 粤英语音键盘 added in Settings. Do not use a real phone or a simulator containing personal data. The tests do not verify microphone capture, a live provider, or third-party apps.

Generate the harness with XcodeGen and build it for testing:

```sh
xcodegen generate --spec Tests/KeyboardUI/project.yml
xcodebuild -project Tests/KeyboardUI/VoiceUIHarness.xcodeproj -scheme VoiceUIHarness \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' build-for-testing
```

Run `VoiceKeyboardUITests/testVoiceLayoutAndTopRowTyping` with Xcode or `test-without-building`; it expects an inactive voice session. It verifies that the return key is inside the 844-point screen, and that the English top row inserts and deletes a character.

`testHeldResultIsInsertedOnce` requires the fictional string `模拟保留结果` under `keyboard_held_result_v1` in the keyboard extension's **own** simulator container preferences, prepared while the simulator is shut down. Merely writing the global simulator preferences domain is not equivalent: that value can remain after the extension removes its own value and produce a false duplicate. Boot the disposable simulator and run this test alone. It expects the keyboard to start on its voice page, verifies explicit insertion into the test field, and checks that reopening the host does not replay the result. Delete the temporary simulator afterwards.
