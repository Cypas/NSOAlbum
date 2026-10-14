String syncFailureStatus(Object error) {
  final value = error.toString().toLowerCase();
  if (value.contains('cancelled') || value.contains('canceled')) {
    return 'cancelled';
  }
  if (value.contains('rate limited') || value.contains('429')) {
    return 'rate_limited';
  }
  if (value.contains('authentication failed') ||
      value.contains('unauthorized') ||
      value.contains('401') ||
      value.contains('token expired') ||
      value.contains('requires sign-in')) {
    return 'authentication_failure';
  }
  return 'failure';
}
