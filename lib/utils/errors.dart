// lib/utils/errors.dart
String parseEdgeError(int status, dynamic data) {
  String bodyMsg = '';
  try {
    if (data is Map && data['error'] is String) bodyMsg = data['error'];
    if (data is String && data.isNotEmpty) bodyMsg = data;
  } catch (_) {}

  switch (status) {
    case 401:
      return 'Please sign in to use the scanner.';
    case 402:
      return 'Service budget reached. Try again later.';
    case 413:
      return 'File too large. Try a smaller file or fewer pages.';
    case 415:
      return 'Unsupported file type. Please upload a PDF or TXT.';
    case 429:
      // Function may send "Daily limit reached" or "Server busy..."
      return bodyMsg.isNotEmpty
          ? bodyMsg
          : 'Too many requests. Try again soon.';
    case 500:
      return 'Something went wrong on our side. Please try again.';
    default:
      return bodyMsg.isNotEmpty ? bodyMsg : 'Error $status. Please try again.';
  }
}
