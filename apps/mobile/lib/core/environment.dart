class EnvironmentConfig {
  static const String _env = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'local',
  );
  static const String _overrideBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
  static const String _offUserAgent = String.fromEnvironment(
    'OFF_USER_AGENT',
    defaultValue: 'FitnessApp/1.0',
  );
  static const String _offCountry = String.fromEnvironment(
    'OFF_COUNTRY',
    defaultValue: 'en:united-kingdom',
  );

  static const Map<String, String> _baseUrls = {
    'local': 'http://localhost:8000',
    'staging': 'https://staging.example.com',
    'prod': 'https://api.example.com',
  };

  static String get apiBaseUrl {
    if (_overrideBaseUrl.isNotEmpty) {
      return _overrideBaseUrl;
    }
    return _baseUrls[_env] ?? _baseUrls['local']!;
  }

  static String get environmentName => _env;

  static String get offUserAgent => _offUserAgent;

  static String get offCountry => _offCountry;
}
