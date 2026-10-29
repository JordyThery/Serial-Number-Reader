# Changelog

## Unreleased

Fixes for what JTKit ROADMAP step 11 (the release check) found, 2026-10-29.

- **After saving an asset tag, the app shows what Jamf stored.** It used to
  show the value as typed; now it reads the record back after the save (if
  that read fails, it shows the saved value as before).
- **An asset tag saved while switching connections no longer shows up under
  the new connection.** The save still goes to the server that was in use, but
  its result isn't put in the new connection's list.
- **A refused Restore or Revive says why.** The sheet closed without a word
  when the restore couldn't start (another one still running, or a real device
  while Demo Mode is on); now it stays open with a message.
- **Demo Mode never asks ipsw.me.** Opening Restore on the pretend iPhone
  checked Apple's signing status for its model online; it now shows a made-up
  signed release ("26.0"). Under tests no lookups are made at all.
- **The unit tests always start with Demo Mode off.** A switch left on in the
  test host's settings by an earlier run could turn it on for one run.
- **The tests leave no settings files behind.** Each run left an empty
  settings file per test in `~/Library/Preferences` (`snr-demo-…`,
  `snr-live-…`, `snr-under-test-…`); their settings now live in a temporary folder
  instead. An empty template test was removed.
- The project no longer lists a leftover `SerialNumberReaderUITests` folder
  from a first attempt at adding the UI test target.
