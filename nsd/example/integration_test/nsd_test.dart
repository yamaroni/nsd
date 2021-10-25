import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsd/nsd.dart';
import 'package:uuid/uuid.dart';

const serviceCount = 9; // 1 discovery + 9 services <= Android limit (10)
const serviceType = '_http._tcp';
const basePort = 56360; // TODO ensure ports are not taken
const uuid = Uuid();
const utf8encoder = Utf8Encoder();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Registration, discovery and unregistration of multiple services',
      (WidgetTester _) async {
    final name = uuid.v4(); // UUID as service name base ensures test isolation

    final discovery = await startDiscovery(serviceType);

    // register simultaneously for a bit of stress
    final futures = Iterable<int>.generate(serviceCount)
        .map((e) => createServiceInfo(name, basePort + e))
        .map((e) => register(e));

    final registrations = await Future.wait(futures);

    // wait for a minimum of ten seconds to ensure there are not more registered services than expected
    await waitForCondition(
        () =>
            findNameStartingWith(discovery.services, name).length ==
            serviceCount,
        minWait: const Duration(seconds: 10));

    // unregister simultaneously for a bit of stress
    await Future.wait(registrations.map((e) => unregister(e)));

    await waitForCondition(
        () => findNameStartingWith(discovery.services, name).isEmpty);

    await stopDiscovery(discovery);
  });

  testWidgets('Verify basic attributes of registered service',
      (WidgetTester _) async {
    final discovery = await startDiscovery(serviceType);

    final name = uuid.v4(); // UUID as service name base ensures test isolation

    final serviceInfo =
        ServiceInfo(name: name, type: serviceType, port: basePort);
    final registration = await register(serviceInfo);

    await waitForCondition(
        () => findNameStartingWith(discovery.services, name).length == 1);

    final receivedServiceInfo =
        findNameStartingWith(discovery.services, name).elementAt(0);

    expect(receivedServiceInfo.name, name);
    expect(receivedServiceInfo.type, serviceType);
    expect(receivedServiceInfo.port, basePort);

    await unregister(registration);
    await stopDiscovery(discovery);
  });

  testWidgets('Verify txt attribute of registered service',
      (WidgetTester _) async {
    final discovery = await startDiscovery(serviceType);

    final name = uuid.v4(); // UUID as service name base ensures test isolation

    final stringValue = utf8encoder.convert('κόσμε');
    final blankValue = Uint8List(0);

    final txt = <String, Uint8List?>{
      'a-string': stringValue,
      'a-blank': blankValue,
      'a-null': null,
    };

    // these bytes cannot appear in a correct UTF-8 string,
    // see https://www.cl.cam.ac.uk/~mgk25/ucs/examples/UTF-8-test.txt
    final binaryValue = Uint8List.fromList([254, 255]);

    // Android's NsdManager doesn't support binary txt data due to signature of
    // NsdServiceInfo.setAttribute(String key, String value)
    if (!Platform.isAndroid) {
      txt['a-binary'] = binaryValue;
    }

    final serviceInfo =
        ServiceInfo(name: name, type: serviceType, port: basePort, txt: txt);
    final registration = await register(serviceInfo);

    await waitForCondition(
        () => findNameStartingWith(discovery.services, name).length == 1);

    final receivedServiceInfo =
        findNameStartingWith(discovery.services, name).elementAt(0);

    final receivedTxt = receivedServiceInfo.txt!;

    // string values are most common
    expect(receivedTxt['a-string'], stringValue);

    // should be present even though it is blank
    expect(receivedTxt.containsKey('a-blank'), true);

    // should theoretically be a blank list but Android / macOS / iOS return null here
    expect(receivedTxt['a-blank'], null);

    // should be present even though it is null
    expect(receivedTxt.containsKey('a-null'), true);

    // null values are supported
    expect(receivedTxt['a-null'], null);

    if (!Platform.isAndroid) {
      expect(receivedTxt['a-binary'], binaryValue);
    }

    await unregister(registration);
    await stopDiscovery(discovery);
  });
}

isBlankOrNull(Uint8List? value) {
  return value == null || value.isEmpty;
}

ServiceInfo createServiceInfo(String name, int port) {
  return ServiceInfo(name: name + ' $port', type: serviceType, port: port);
}

Iterable<ServiceInfo> findNameStartingWith(
        List<ServiceInfo> serviceInfos, String name) =>
    serviceInfos.where((serviceInfo) => serviceInfo.name!.startsWith(name));

Future<void> waitForCondition(bool Function() condition,
    {Duration minWait = const Duration(),
    Duration maxWait = const Duration(minutes: 1)}) async {
  final start = DateTime.now();
  final min = start.add(minWait);
  final max = start.add(maxWait);

  while (true) {
    final now = DateTime.now();

    if (min.isBefore(now)) {
      if (condition()) {
        return;
      }

      if (now.isAfter(max)) {
        throw TimeoutException('Timeout while waiting for condition', maxWait);
      }
    }

    await Future.delayed(const Duration(milliseconds: 500));
  }
}
