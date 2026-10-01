import 'package:flutter_test/flutter_test.dart';
import 'package:on_chain/on_chain.dart';

void main() {
  test('intent prefix + variant BCS equals serializeSign', () {
    final owner = SuiAddress('0x${'11' * 32}');
    final tx = SuiTransactionDataV1(
      expiration: const SuiTransactionExpirationNone(),
      sender: owner,
      gasData: SuiGasData(
        payment: const [],
        owner: owner,
        price: BigInt.from(1000),
        budget: BigInt.from(1000000),
      ),
      kind: SuiTransactionKindProgrammableTransaction(
        SuiProgrammableTransaction(inputs: const [], commands: const []),
      ),
    );
    final bcs = tx.toVariantBcs();
    expect(bcs.last, 0); // None expiration is the trailing byte
    expect(tx.serializeSign(), [0, 0, 0, ...bcs]);
  });
}
