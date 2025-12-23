class InvoiceTypeModel {
  final String value;
  final String label;
  final String description;

  const InvoiceTypeModel({
    required this.value,
    required this.label,
    required this.description,
  });

  factory InvoiceTypeModel.fromJson(Map<String, dynamic> json) {
    return InvoiceTypeModel(
      value: json['value'] as String,
      label: json['label'] as String,
      description: json['description'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      'label': label,
      'description': description,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InvoiceTypeModel &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}
