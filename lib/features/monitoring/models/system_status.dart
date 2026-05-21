class SystemStatus {
  final bool isInternetConnected;
  final bool isPrinterConnected;
  final bool isPmrConnected;
  final int pendingTransactions;

  SystemStatus({
    this.isInternetConnected = false,
    this.isPrinterConnected = false,
    this.isPmrConnected = false,
    this.pendingTransactions = 0,
  });

  SystemStatus copyWith({
    bool? isInternetConnected,
    bool? isPrinterConnected,
    bool? isPmrConnected,
    int? pendingTransactions,
  }) {
    return SystemStatus(
      isInternetConnected: isInternetConnected ?? this.isInternetConnected,
      isPrinterConnected: isPrinterConnected ?? this.isPrinterConnected,
      isPmrConnected: isPmrConnected ?? this.isPmrConnected,
      pendingTransactions: pendingTransactions ?? this.pendingTransactions,
    );
  }
}
