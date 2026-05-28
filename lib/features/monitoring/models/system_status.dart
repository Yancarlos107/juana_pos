class SystemStatus {
  final bool isInternetConnected;
  final bool isPrinterConnected;
  final bool isPmrConnected;
  final bool isCameraConnected;
  final int pendingTransactions;

  SystemStatus({
    this.isInternetConnected = false,
    this.isPrinterConnected = false,
    this.isPmrConnected = false,
    this.isCameraConnected = false,
    this.pendingTransactions = 0,
  });

  SystemStatus copyWith({
    bool? isInternetConnected,
    bool? isPrinterConnected,
    bool? isPmrConnected,
    bool? isCameraConnected,
    int? pendingTransactions,
  }) {
    return SystemStatus(
      isInternetConnected: isInternetConnected ?? this.isInternetConnected,
      isPrinterConnected: isPrinterConnected ?? this.isPrinterConnected,
      isPmrConnected: isPmrConnected ?? this.isPmrConnected,
      isCameraConnected: isCameraConnected ?? this.isCameraConnected,
      pendingTransactions: pendingTransactions ?? this.pendingTransactions,
    );
  }
}
