# Security

Keep go2rtc on your home network. Do not forward its ports to the internet.

The app sends the go2rtc password as HTTP basic auth over plain HTTP. Anyone who can capture traffic on your Wi-Fi can read it. go2rtc supports TLS, but the app does not use it yet.

With stock settings, that password also opens go2rtc's admin API. `/api/config` shows the whole config, including the Xiaomi token, and can rewrite it. These go2rtc settings limit what the password can do:

```yaml
api:
  # Only the paths this app uses. This also hides /api/config.
  allow_paths: ["/api/streams", "/api/ws", "/api/xiaomi", "/api/xiaomi/command"]
  # Require the password from programs on the go2rtc host too.
  local_auth: true
  # Leave out origin: "*"; the app does not need it.
```

`allow_paths` also turns off the go2rtc web page. Add `"/"` and `"/api"` back for a moment when you need to log in to Xiaomi again.
