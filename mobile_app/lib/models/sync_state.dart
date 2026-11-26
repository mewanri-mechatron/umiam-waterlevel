class SyncState {
  const SyncState({
    this.id,
    required this.stationId,
    this.lastDownloadTime,
    this.lastUploadTime,
    this.pendingUploadCount = 0,
    this.lastGatewayContact,
    this.uploadedCount = 0,
    this.failedUploadCount = 0,
    this.lastEspAckId = 0,
  });

  final int? id;
  final String stationId;
  final int? lastDownloadTime;
  final int? lastUploadTime;
  final int pendingUploadCount;
  final int? lastGatewayContact;
  final int uploadedCount;
  final int failedUploadCount;

  /// Highest Node B queue id we have told the ESP it may delete.
  final int lastEspAckId;

  SyncState copyWith({
    int? lastDownloadTime,
    int? lastUploadTime,
    int? pendingUploadCount,
    int? lastGatewayContact,
    int? uploadedCount,
    int? failedUploadCount,
    int? lastEspAckId,
  }) {
    return SyncState(
      id: id,
      stationId: stationId,
      lastDownloadTime: lastDownloadTime ?? this.lastDownloadTime,
      lastUploadTime: lastUploadTime ?? this.lastUploadTime,
      pendingUploadCount: pendingUploadCount ?? this.pendingUploadCount,
      lastGatewayContact: lastGatewayContact ?? this.lastGatewayContact,
      uploadedCount: uploadedCount ?? this.uploadedCount,
      failedUploadCount: failedUploadCount ?? this.failedUploadCount,
      lastEspAckId: lastEspAckId ?? this.lastEspAckId,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'station_id': stationId,
        'last_download_time': lastDownloadTime,
        'last_upload_time': lastUploadTime,
        'pending_upload_count': pendingUploadCount,
        'last_gateway_contact': lastGatewayContact,
        'uploaded_count': uploadedCount,
        'failed_upload_count': failedUploadCount,
        'last_esp_ack_id': lastEspAckId,
      };

  factory SyncState.fromMap(Map<String, Object?> map) => SyncState(
        id: map['id'] as int?,
        stationId: map['station_id']! as String,
        lastDownloadTime: map['last_download_time'] as int?,
        lastUploadTime: map['last_upload_time'] as int?,
        pendingUploadCount: map['pending_upload_count'] as int? ?? 0,
        lastGatewayContact: map['last_gateway_contact'] as int?,
        uploadedCount: map['uploaded_count'] as int? ?? 0,
        failedUploadCount: map['failed_upload_count'] as int? ?? 0,
        lastEspAckId: map['last_esp_ack_id'] as int? ?? 0,
      );
}
