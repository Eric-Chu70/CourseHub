class AppConfig {
  static const String leancloudAppId = 'YOUR_LEANCLOUD_APP_ID';
  static const String leancloudAppKey = 'YOUR_LEANCLOUD_APP_KEY';
  static const String leancloudApiUrl = 'https://YOUR_LEANCLOUD_API_URL';
  
  static bool get isConfigured =>
      leancloudAppId != 'YOUR_LEANCLOUD_APP_ID' &&
      leancloudAppKey != 'YOUR_LEANCLOUD_APP_KEY' &&
      leancloudApiUrl != 'https://YOUR_LEANCLOUD_API_URL';
}
