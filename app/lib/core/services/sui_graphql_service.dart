import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:on_chain/on_chain.dart';

/// True for network-level failures (dropped connection, DNS blip, timeout)
/// worth a quiet retry. False for anything the server actually responded to
/// — a bad status code or a GraphQL `errors` payload means the request was
/// received and rejected, so retrying it would just repeat the failure.
bool _isTransientNetworkError(Object error) {
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}

/// Retries [request] on transient network errors only. Bounded and short by
/// design: this runs underneath higher-level retry/backoff already in the
/// app (see GraniteLakeController's verification retry), so it exists to
/// smooth over brief blips, not to carry the app through a real outage.
Future<T> _withNetworkRetry<T>(
  Future<T> Function() request, {
  int attempts = 3,
  Duration baseDelay = const Duration(milliseconds: 300),
}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await request();
    } catch (error) {
      if (attempt == attempts || !_isTransientNetworkError(error)) {
        rethrow;
      }
      await Future<void>.delayed(baseDelay * pow(2, attempt - 1));
    }
  }
  throw StateError('unreachable');
}

class SuiGraphQlObject {
  const SuiGraphQlObject({
    required this.objectId,
    required this.version,
    required this.digest,
    required this.ownerKind,
    required this.ownerAddress,
    required this.initialSharedVersion,
    required this.type,
    required this.previousTransaction,
    required this.json,
  });

  final String objectId;
  final BigInt version;
  final String digest;
  final String ownerKind;
  final String? ownerAddress;
  final BigInt? initialSharedVersion;
  final String? type;
  final String? previousTransaction;
  final Map<String, dynamic>? json;

  SuiObjectRef toObjectRef() {
    return SuiObjectRef(
      address: SuiAddress(objectId),
      version: version,
      digest: SuiObjectDigest.fromBase58(digest),
    );
  }
}

class SuiGraphQlEvent {
  const SuiGraphQlEvent({
    required this.type,
    required this.packageId,
    required this.transactionModule,
    required this.sender,
    required this.timestamp,
    required this.parsedJson,
  });

  final String type;
  final String packageId;
  final String transactionModule;
  final String sender;
  final DateTime? timestamp;
  final Map<String, dynamic>? parsedJson;
}

class SuiGraphQlObjectChange {
  const SuiGraphQlObjectChange({
    required this.objectId,
    required this.idCreated,
    required this.idDeleted,
    required this.outputState,
  });

  final String objectId;
  final bool idCreated;
  final bool idDeleted;
  final SuiGraphQlObject? outputState;
}

class SuiGraphQlGasSummary {
  const SuiGraphQlGasSummary({
    required this.computationCost,
    required this.storageCost,
    required this.storageRebate,
    required this.nonRefundableStorageFee,
  });

  final BigInt computationCost;
  final BigInt storageCost;
  final BigInt storageRebate;
  final BigInt nonRefundableStorageFee;
}

class SuiGraphQlTransactionResult {
  const SuiGraphQlTransactionResult({
    required this.digest,
    required this.sender,
    required this.status,
    required this.error,
    required this.timestamp,
    required this.events,
    required this.objectChanges,
    required this.gasSummary,
    required this.gasObject,
  });

  final String digest;
  final String? sender;
  final String status;
  final String? error;
  final DateTime? timestamp;
  final List<SuiGraphQlEvent> events;
  final List<SuiGraphQlObjectChange> objectChanges;
  final SuiGraphQlGasSummary? gasSummary;
  final SuiGraphQlObject? gasObject;
}

class SuiGraphQlService {
  SuiGraphQlService({
    http.Client? client,
    this.defaultTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration defaultTimeout;

  String normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return trimmed;
    }

    final host = uri.host.toLowerCase();
    if (host == 'fullnode.testnet.sui.io') {
      return 'https://graphql.testnet.sui.io/graphql';
    }
    if (host == 'fullnode.mainnet.sui.io') {
      return 'https://graphql.mainnet.sui.io/graphql';
    }
    if (host == 'fullnode.devnet.sui.io') {
      return 'https://graphql.devnet.sui.io/graphql';
    }

    if (host.startsWith('graphql.') && !uri.path.endsWith('/graphql')) {
      return uri.replace(path: '/graphql').toString();
    }

    return trimmed;
  }

  Future<BigInt> getReferenceGasPrice(String url) async {
    final data = await _request(
      url,
      query: 'query { epoch { referenceGasPrice } }',
    );
    final epoch = _asMap(data['epoch']);
    return BigInt.parse(_asString(epoch['referenceGasPrice']));
  }

  Future<BigInt> getSuiBalance(
    String url, {
    required String ownerAddress,
  }) async {
    final data = await _request(
      url,
      query: r'''query($address:SuiAddress!){
        address(address:$address){
          balance(coinType:"0x2::sui::SUI"){
            totalBalance
          }
        }
      }''',
      variables: {'address': ownerAddress},
    );
    final address = _asMap(data['address']);
    final balance = address['balance'];
    if (balance == null) {
      return BigInt.zero;
    }
    return BigInt.parse(_asString(_asMap(balance)['totalBalance']));
  }

  Future<SuiGraphQlObject?> getObject(
    String url, {
    required String objectId,
  }) async {
    final data = await _request(
      url,
      query: r'''query($id:SuiAddress!){
        object(address:$id){
          address
          version
          digest
          owner {
            __typename
            ... on AddressOwner { address { address } }
            ... on ObjectOwner { address { address } }
            ... on Shared { initialSharedVersion }
          }
          previousTransaction { digest }
          asMoveObject {
            contents {
              type { repr }
              json
            }
          }
        }
      }''',
      variables: {'id': objectId},
    );

    final object = data['object'];
    if (object == null) {
      return null;
    }
    return _parseObjectNode(_asMap(object));
  }

  Future<List<SuiGraphQlObject>> listOwnedObjectsByType(
    String url, {
    required String ownerAddress,
    required String type,
    int pageSize = 50,
  }) async {
    final objects = <SuiGraphQlObject>[];
    String? after;
    var hasNextPage = true;

    while (hasNextPage) {
      final data = await _request(
        url,
        query:
            r'''query($address:SuiAddress!, $type:String!, $first:Int!, $after:String){
          address(address:$address){
            objects(first:$first, after:$after, filter:{ type:$type }){
              pageInfo { hasNextPage endCursor }
              nodes {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                  ... on ObjectOwner { address { address } }
                  ... on Shared { initialSharedVersion }
                }
                previousTransaction { digest }
                contents {
                  type { repr }
                  json
                }
              }
            }
          }
        }''',
        variables: {
          'address': ownerAddress,
          'type': type,
          'first': pageSize,
          'after': after,
        },
      );

      final address = _asMap(data['address']);
      final connection = _asMap(address['objects']);
      final nodes = _asList(connection['nodes']);
      for (final node in nodes) {
        objects.add(_parseMoveObjectNode(_asMap(node)));
      }

      final pageInfo = _asMap(connection['pageInfo']);
      hasNextPage = pageInfo['hasNextPage'] == true;
      after = hasNextPage ? pageInfo['endCursor'] as String? : null;
    }

    return objects;
  }

  Future<SuiGraphQlTransactionResult> getTransaction(
    String url, {
    required String digest,
  }) async {
    final data = await _request(
      url,
      query: r'''query($digest:String!){
        transaction(digest:$digest){
          digest
          sender { address }
          effects {
            digest
            status
            timestamp
            executionError { message }
            gasEffects {
              gasSummary {
                computationCost
                storageCost
                storageRebate
                nonRefundableStorageFee
              }
              gasObject {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                  ... on ObjectOwner { address { address } }
                  ... on Shared { initialSharedVersion }
                }
                previousTransaction { digest }
                asMoveObject {
                  contents {
                    type { repr }
                    json
                  }
                }
              }
            }
            events {
              nodes {
                sender { address }
                timestamp
                transactionModule {
                  name
                  package { address }
                }
                contents {
                  type { repr }
                  json
                }
              }
            }
            objectChanges {
              nodes {
                address
                idCreated
                idDeleted
                outputState {
                  address
                  version
                  digest
                  owner {
                    __typename
                    ... on AddressOwner { address { address } }
                    ... on ObjectOwner { address { address } }
                    ... on Shared { initialSharedVersion }
                  }
                  previousTransaction { digest }
                  asMoveObject {
                    contents {
                      type { repr }
                      json
                    }
                  }
                }
              }
            }
          }
        }
      }''',
      variables: {'digest': digest},
    );

    final transactionNode = data['transaction'];
    if (transactionNode == null) {
      throw StateError(
        'Transaction not found for digest $digest. It may not be indexed yet.',
      );
    }
    return _parseTransactionNode(_asMap(transactionNode));
  }

  Future<SuiGraphQlTransactionResult> simulateTransaction(
    String url, {
    required String transactionDataBcs,
  }) async {
    final data = await _request(
      url,
      query: r'''query($tx:JSON!){
        simulateTransaction(transaction:$tx, checksEnabled:true, doGasSelection:true){
          effects {
            digest
            status
            timestamp
            executionError { message }
            gasEffects {
              gasSummary {
                computationCost
                storageCost
                storageRebate
                nonRefundableStorageFee
              }
              gasObject {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                  ... on ObjectOwner { address { address } }
                  ... on Shared { initialSharedVersion }
                }
                previousTransaction { digest }
                asMoveObject {
                  contents {
                    type { repr }
                    json
                  }
                }
              }
            }
            events {
              nodes {
                sender { address }
                timestamp
                transactionModule {
                  name
                  package { address }
                }
                contents {
                  type { repr }
                  json
                }
              }
            }
            objectChanges {
              nodes {
                address
                idCreated
                idDeleted
                outputState {
                  address
                  version
                  digest
                  owner {
                    __typename
                    ... on AddressOwner { address { address } }
                    ... on ObjectOwner { address { address } }
                    ... on Shared { initialSharedVersion }
                  }
                  previousTransaction { digest }
                  asMoveObject {
                    contents {
                      type { repr }
                      json
                    }
                  }
                }
              }
            }
          }
        }
      }''',
      variables: {
        'tx': {
          'bcs': {'value': transactionDataBcs},
        },
      },
    );

    return _parseEffectsNode(
      _asMap(_asMap(data['simulateTransaction'])['effects']),
    );
  }

  Future<SuiGraphQlTransactionResult> executeTransaction(
    String url, {
    required String transactionDataBcs,
    required List<String> signatures,
  }) async {
    final data = await _request(
      url,
      query: r'''mutation($tx:Base64!, $sigs:[Base64!]!){
        executeTransaction(transactionDataBcs:$tx, signatures:$sigs){
          effects {
            digest
            status
            timestamp
            executionError { message }
            gasEffects {
              gasSummary {
                computationCost
                storageCost
                storageRebate
                nonRefundableStorageFee
              }
              gasObject {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                  ... on ObjectOwner { address { address } }
                  ... on Shared { initialSharedVersion }
                }
                previousTransaction { digest }
                asMoveObject {
                  contents {
                    type { repr }
                    json
                  }
                }
              }
            }
            events {
              nodes {
                sender { address }
                timestamp
                transactionModule {
                  name
                  package { address }
                }
                contents {
                  type { repr }
                  json
                }
              }
            }
            objectChanges {
              nodes {
                address
                idCreated
                idDeleted
                outputState {
                  address
                  version
                  digest
                  owner {
                    __typename
                    ... on AddressOwner { address { address } }
                    ... on ObjectOwner { address { address } }
                    ... on Shared { initialSharedVersion }
                  }
                  previousTransaction { digest }
                  asMoveObject {
                    contents {
                      type { repr }
                      json
                    }
                  }
                }
              }
            }
          }
        }
      }''',
      variables: {'tx': transactionDataBcs, 'sigs': signatures},
    );

    return _parseEffectsNode(
      _asMap(_asMap(data['executeTransaction'])['effects']),
    );
  }

  Future<Map<String, dynamic>> _request(
    String url, {
    required String query,
    Map<String, dynamic>? variables,
  }) async {
    final normalizedUrl = normalizeUrl(url);
    final response = await _withNetworkRetry(
      () => _client
          .post(
            Uri.parse(normalizedUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'query': query,
              ...?variables == null ? null : {'variables': variables},
            }),
          )
          .timeout(defaultTimeout),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final legacyHint = normalizedUrl != url.trim()
          ? ' Normalized legacy endpoint $url to $normalizedUrl before the request.'
          : '';
      throw StateError(
        'Sui GraphQL request failed (${response.statusCode}) against $normalizedUrl: ${response.body}$legacyHint',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException(
        'Sui GraphQL response was not a JSON object.',
      );
    }

    final payload = Map<String, dynamic>.from(decoded);
    final errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      final messages = errors
          .whereType<Map>()
          .map((entry) => entry['message']?.toString().trim() ?? '')
          .where((message) => message.isNotEmpty)
          .toList(growable: false);
      throw StateError(
        messages.isEmpty ? 'Sui GraphQL request failed.' : messages.join('\n'),
      );
    }

    final data = payload['data'];
    if (data is! Map) {
      throw const FormatException(
        'Sui GraphQL response did not contain a data object.',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  SuiGraphQlTransactionResult _parseTransactionNode(Map<String, dynamic> node) {
    final parsed = _parseEffectsNode(_asMap(node['effects']));
    return SuiGraphQlTransactionResult(
      digest: parsed.digest,
      sender: _asMap(node['sender'])['address'] as String?,
      status: parsed.status,
      error: parsed.error,
      timestamp: parsed.timestamp,
      events: parsed.events,
      objectChanges: parsed.objectChanges,
      gasSummary: parsed.gasSummary,
      gasObject: parsed.gasObject,
    );
  }

  SuiGraphQlTransactionResult _parseEffectsNode(Map<String, dynamic> effects) {
    final gasEffects = effects['gasEffects'] == null
        ? null
        : _asMap(effects['gasEffects']);
    final gasSummary = gasEffects == null || gasEffects['gasSummary'] == null
        ? null
        : _parseGasSummary(_asMap(gasEffects['gasSummary']));
    final gasObject = gasEffects == null || gasEffects['gasObject'] == null
        ? null
        : _parseObjectNode(_asMap(gasEffects['gasObject']));
    final eventNodes = effects['events'] == null
        ? const <dynamic>[]
        : _asList(_asMap(effects['events'])['nodes']);
    final objectChangeNodes = effects['objectChanges'] == null
        ? const <dynamic>[]
        : _asList(_asMap(effects['objectChanges'])['nodes']);

    return SuiGraphQlTransactionResult(
      digest: _asString(effects['digest']),
      sender: null,
      status: _asString(effects['status']),
      error: effects['executionError'] == null
          ? null
          : _asMap(effects['executionError'])['message'] as String?,
      timestamp: _parseDateTime(effects['timestamp']),
      events: eventNodes
          .map((node) => _parseEventNode(_asMap(node)))
          .toList(growable: false),
      objectChanges: objectChangeNodes
          .map((node) => _parseObjectChangeNode(_asMap(node)))
          .toList(growable: false),
      gasSummary: gasSummary,
      gasObject: gasObject,
    );
  }

  SuiGraphQlGasSummary _parseGasSummary(Map<String, dynamic> node) {
    return SuiGraphQlGasSummary(
      computationCost: BigInt.parse(_asString(node['computationCost'])),
      storageCost: BigInt.parse(_asString(node['storageCost'])),
      storageRebate: BigInt.parse(_asString(node['storageRebate'])),
      nonRefundableStorageFee: BigInt.parse(
        _asString(node['nonRefundableStorageFee']),
      ),
    );
  }

  SuiGraphQlEvent _parseEventNode(Map<String, dynamic> node) {
    final transactionModule = _asMap(node['transactionModule']);
    final contents = _asMap(node['contents']);
    return SuiGraphQlEvent(
      type: _asString(_asMap(contents['type'])['repr']),
      packageId: _asString(_asMap(transactionModule['package'])['address']),
      transactionModule: _asString(transactionModule['name']),
      sender: _asString(_asMap(node['sender'])['address']),
      timestamp: _parseDateTime(node['timestamp']),
      parsedJson: contents['json'] is Map
          ? Map<String, dynamic>.from(contents['json'] as Map)
          : null,
    );
  }

  SuiGraphQlObjectChange _parseObjectChangeNode(Map<String, dynamic> node) {
    return SuiGraphQlObjectChange(
      objectId: _asString(node['address']),
      idCreated: node['idCreated'] == true,
      idDeleted: node['idDeleted'] == true,
      outputState: node['outputState'] == null
          ? null
          : _parseObjectNode(_asMap(node['outputState'])),
    );
  }

  SuiGraphQlObject _parseMoveObjectNode(Map<String, dynamic> node) {
    return _parseObjectNode(node, moveContentsKey: 'contents');
  }

  SuiGraphQlObject _parseObjectNode(
    Map<String, dynamic> node, {
    String moveContentsKey = 'asMoveObject',
  }) {
    final owner = node['owner'] == null ? null : _asMap(node['owner']);
    final ownerType = owner == null ? '' : _asString(owner['__typename']);

    String? ownerAddress;
    BigInt? initialSharedVersion;
    if (ownerType == 'AddressOwner' || ownerType == 'ObjectOwner') {
      final addressNode = owner == null ? null : owner['address'];
      if (addressNode is Map) {
        ownerAddress = addressNode['address'] as String?;
      }
    } else if (ownerType == 'Shared' &&
        owner != null &&
        owner['initialSharedVersion'] != null) {
      initialSharedVersion = BigInt.parse(
        _asString(owner['initialSharedVersion']),
      );
    }

    Map<String, dynamic>? contents;
    if (moveContentsKey == 'contents') {
      contents = node['contents'] is Map
          ? Map<String, dynamic>.from(node['contents'] as Map)
          : null;
    } else {
      final asMoveObject = node['asMoveObject'] is Map
          ? Map<String, dynamic>.from(node['asMoveObject'] as Map)
          : null;
      contents = asMoveObject?['contents'] is Map
          ? Map<String, dynamic>.from(asMoveObject!['contents'] as Map)
          : null;
    }

    return SuiGraphQlObject(
      objectId: _asString(node['address']),
      version: BigInt.parse(_asString(node['version'])),
      digest: _asString(node['digest']),
      ownerKind: ownerType,
      ownerAddress: ownerAddress,
      initialSharedVersion: initialSharedVersion,
      type: contents == null || contents['type'] == null
          ? null
          : _asString(_asMap(contents['type'])['repr']),
      previousTransaction: node['previousTransaction'] == null
          ? null
          : _asMap(node['previousTransaction'])['digest'] as String?,
      json: contents != null && contents['json'] is Map
          ? Map<String, dynamic>.from(contents['json'] as Map)
          : null,
    );
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    throw const FormatException(
      'Expected a JSON object in the Sui GraphQL response.',
    );
  }

  List<dynamic> _asList(Object? value) {
    return value is List ? value : const <dynamic>[];
  }

  String _asString(Object? value) {
    if (value == null) {
      throw const FormatException(
        'Expected a string value in the Sui GraphQL response.',
      );
    }
    return value.toString();
  }

  DateTime? _parseDateTime(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString())?.toUtc();
  }
}
