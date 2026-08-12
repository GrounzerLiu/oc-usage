/// Windows DPAPI 加解密（crypt32.dll，无额外依赖）。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);

typedef _ProtectDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

Uint8List dpapiProtect(Uint8List data) => _dpapi(true, data);

Uint8List dpapiUnprotect(Uint8List data) => _dpapi(false, data);

Uint8List _dpapi(bool protect, Uint8List data) {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final fn = crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
    protect ? 'CryptProtectData' : 'CryptUnprotectData',
  );
  final localFree = kernel32.lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  final input = calloc<_DataBlob>();
  final dataPtr = calloc<Uint8>(data.length);
  dataPtr.asTypedList(data.length).setAll(0, data);
  input.ref
    ..cbData = data.length
    ..pbData = dataPtr;

  final output = calloc<_DataBlob>();
  final ok = fn(input, nullptr, nullptr, nullptr, nullptr, 0, output);
  calloc.free(input);
  calloc.free(dataPtr);
  if (ok == 0) {
    calloc.free(output);
    throw StateError('DPAPI ${protect ? 'protect' : 'unprotect'} failed');
  }
  final result = Uint8List.fromList(
    output.ref.pbData.asTypedList(output.ref.cbData),
  );
  localFree(output.ref.pbData.cast<Void>());
  calloc.free(output);
  return result;
}
