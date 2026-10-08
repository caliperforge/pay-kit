"""Pinned-seed negative cases for the fee-payer co-sign instruction allowlist.

Opt-in, kept out of default CI:
    just allowlist-gen
"""

from __future__ import annotations

import base64
import os
import random
from collections.abc import Callable
from typing import NamedTuple

import pytest
from solders.hash import Hash
from solders.instruction import AccountMeta, Instruction
from solders.keypair import Keypair
from solders.message import MessageV0
from solders.pubkey import Pubkey
from solders.system_program import TransferParams, transfer
from solders.transaction import VersionedTransaction

from solana_pay_kit._paycore.errors import CODE_PAYMENT_INVALID, PaymentError, canonical_code
from solana_pay_kit._paycore.solana import ASSOCIATED_TOKEN_PROGRAM, TOKEN_PROGRAM, MethodDetails, resolve_mint
from solana_pay_kit.protocols.mpp.intents.charge import ChargeRequest
from solana_pay_kit.protocols.mpp.server._tx_decode import (
    _COMPUTE_BUDGET_PROGRAM,
    _MEMO_V1_PROGRAM,
    _SYSTEM_PROGRAM,
    MAX_COMPUTE_UNIT_LIMIT,
    MAX_COMPUTE_UNIT_PRICE_MICROLAMPORTS,
    MAX_COMPUTE_UNIT_PRICE_MICROLAMPORTS_FEE_SPONSORED,
)
from solana_pay_kit.protocols.mpp.server.charge import _validate_instruction_allowlist

SEED = int(os.environ.get("PAY_KIT_ALLOWLIST_GEN_SEED", "108"))
CASES = int(os.environ.get("PAY_KIT_ALLOWLIST_GEN_CASES", "240"))

BLOCKHASH = Hash.from_string("4vJ9JU1bJJQpUgJ8V6hYz7xXKz4F2tN6aBrZEcD3xKhs")
MINT = Pubkey.from_string(resolve_mint("USDC", "devnet"))
TOKEN = Pubkey.from_string(TOKEN_PROGRAM)
ATA_PROGRAM = Pubkey.from_string(ASSOCIATED_TOKEN_PROGRAM)
SOL = (False, False)
SPONSORED_SOL = (False, True)
USDC = (True, False)
SPONSORED_USDC = (True, True)
BASES = (SOL, SPONSORED_SOL, USDC, SPONSORED_USDC)

Case = tuple[str, ChargeRequest, MethodDetails, str | None]


class _Base(NamedTuple):
    fee_payer: Keypair
    client: Keypair
    recipient: Pubkey
    amount: int
    usdc: bool
    sponsored: bool


_Built = tuple[_Base, list[Instruction]]


def _key(rng: random.Random) -> Keypair:
    return Keypair.from_seed(rng.randbytes(32))


def _base(rng: random.Random, usdc: bool, sponsored: bool) -> _Base:
    return _Base(_key(rng), _key(rng), _key(rng).pubkey(), rng.randint(2, 10**12), usdc, sponsored)


def _ata(owner: Pubkey) -> Pubkey:
    return Pubkey.find_program_address([bytes(owner), bytes(TOKEN), bytes(MINT)], ATA_PROGRAM)[0]


def _sol_transfer(source: Pubkey, destination: Pubkey, lamports: int) -> Instruction:
    return transfer(TransferParams(from_pubkey=source, to_pubkey=destination, lamports=lamports))


def _token_transfer(source: Pubkey, destination: Pubkey, authority: Pubkey, amount: int) -> Instruction:
    return Instruction(
        TOKEN,
        bytes([12]) + amount.to_bytes(8, "little") + bytes([6]),
        [
            AccountMeta(source, False, True),
            AccountMeta(MINT, False, False),
            AccountMeta(destination, False, True),
            AccountMeta(authority, True, False),
        ],
    )


def _payment(base: _Base) -> Instruction:
    if not base.usdc:
        return _sol_transfer(base.client.pubkey(), base.recipient, base.amount)
    client = base.client.pubkey()
    return _token_transfer(_ata(client), _ata(base.recipient), client, base.amount)


def _around(rng: random.Random, base: _Base, extra: Instruction) -> _Built:
    return base, rng.choice(([extra, _payment(base)], [_payment(base), extra]))


def _compute_budget(data: bytes, accounts: list[AccountMeta]) -> Instruction:
    return Instruction(Pubkey.from_string(_COMPUTE_BUDGET_PROGRAM), data, accounts)


def _compile(base: _Base, instructions: list[Instruction]) -> Case:
    message = MessageV0.try_compile(base.fee_payer.pubkey(), instructions, [], BLOCKHASH)
    signer_keys = message.account_keys[: message.header.num_required_signatures]
    signers = [kp for kp in (base.fee_payer, base.client) if kp.pubkey() in signer_keys]
    tx_b64 = base64.b64encode(bytes(VersionedTransaction(message, signers))).decode("ascii")
    fee_payer = str(base.fee_payer.pubkey()) if base.sponsored else None
    request = ChargeRequest(
        amount=str(base.amount),
        currency="USDC" if base.usdc else "SOL",
        recipient=str(base.recipient),
    )
    details = MethodDetails(
        network="devnet",
        decimals=6 if base.usdc else None,
        token_program=TOKEN_PROGRAM if base.usdc else None,
        fee_payer=base.sponsored,
        fee_payer_key=fee_payer or "",
    )
    return tx_b64, request, details, fee_payer


def _drain(rng: random.Random) -> _Built:
    base = _base(rng, *rng.choice((SPONSORED_SOL, SPONSORED_USDC)))
    amount = rng.choice((base.amount, base.amount - 1, base.amount + 1, 0, 2**64 - 1))
    payer = base.fee_payer.pubkey()
    if not base.usdc:
        return base, [_sol_transfer(payer, base.recipient, amount)]
    client = base.client.pubkey()
    source, authority = rng.choice(((_ata(payer), payer), (_ata(client), payer), (_ata(payer), client)))
    return base, [_token_transfer(source, _ata(base.recipient), authority, amount)]


def _extra_system_transfer(rng: random.Random) -> _Built:
    base = _base(rng, *rng.choice((SOL, SPONSORED_SOL)))
    client = base.client.pubkey()
    extras = [_sol_transfer(client, base.recipient, base.amount + delta) for delta in (-1, 0, 1)]
    extras.append(_sol_transfer(client, _key(rng).pubkey(), base.amount))
    return _around(rng, base, rng.choice(extras))


def _unknown_program(rng: random.Random) -> _Built:
    base = _base(rng, *rng.choice(BASES))
    return _around(rng, base, Instruction(_key(rng).pubkey(), rng.randbytes(rng.randint(0, 64)), []))


def _memo_v1(rng: random.Random) -> _Built:
    base = _base(rng, *rng.choice(BASES))
    data = rng.randbytes(rng.choice((0, rng.randint(1, 64))))
    return _around(rng, base, Instruction(Pubkey.from_string(_MEMO_V1_PROGRAM), data, []))


def _attacker_ata(rng: random.Random) -> _Built:
    base = _base(rng, *USDC)
    owner = rng.choice((_key(rng).pubkey(), base.recipient))
    create = Instruction(
        ATA_PROGRAM,
        b"\x01",
        [
            AccountMeta(base.fee_payer.pubkey(), True, True),
            AccountMeta(_ata(owner), False, True),
            AccountMeta(owner, False, False),
            AccountMeta(MINT, False, False),
            AccountMeta(Pubkey.from_string(_SYSTEM_PROGRAM), False, False),
            AccountMeta(TOKEN, False, False),
        ],
    )
    return _around(rng, base, create)


def _oversized_compute_budget(rng: random.Random) -> _Built:
    def limit(units: int) -> bytes:
        return bytes([2]) + units.to_bytes(4, "little")

    def price(microlamports: int) -> bytes:
        return bytes([3]) + microlamports.to_bytes(8, "little")

    valid_limit = limit(rng.randint(0, MAX_COMPUTE_UNIT_LIMIT))
    shapes: list[tuple[tuple[tuple[bool, bool], ...], bytes, list[AccountMeta]]] = [
        (BASES, limit(rng.choice((MAX_COMPUTE_UNIT_LIMIT + 1, 2**32 - 1))), []),
        ((SOL, USDC), price(MAX_COMPUTE_UNIT_PRICE_MICROLAMPORTS + 1), []),
        ((SPONSORED_SOL, SPONSORED_USDC), price(MAX_COMPUTE_UNIT_PRICE_MICROLAMPORTS_FEE_SPONSORED + 1), []),
        (BASES, bytes([0]) + valid_limit[1:], []),
        (BASES, valid_limit, [AccountMeta(_key(rng).pubkey(), False, False)]),
    ]
    bases, data, accounts = rng.choice(shapes)
    return _around(rng, _base(rng, *rng.choice(bases)), _compute_budget(data, accounts))


FAMILIES: tuple[Callable[[random.Random], _Built], ...] = (
    _drain,
    _extra_system_transfer,
    _unknown_program,
    _memo_v1,
    _attacker_ata,
    _oversized_compute_budget,
)


def _case(seed: int, i: int) -> Case:
    rng = random.Random(seed * 1_000_003 + i)
    return _compile(*FAMILIES[i % len(FAMILIES)](rng))


@pytest.mark.parametrize("i", range(CASES))
def test_generated_case_is_refused(i: int) -> None:
    tx_b64, request, details, fee_payer = _case(SEED, i)
    with pytest.raises(PaymentError) as exc:
        _validate_instruction_allowlist(tx_b64, request, details, fee_payer)
    assert canonical_code(exc.value.code) == CODE_PAYMENT_INVALID


def test_cases_cover_every_family() -> None:
    assert len(FAMILIES) <= CASES


def test_same_seed_gives_identical_cases() -> None:
    assert [_case(SEED, i)[0] for i in range(CASES)] == [_case(SEED, i)[0] for i in range(CASES)]


@pytest.mark.parametrize(("usdc", "sponsored"), BASES)
def test_unmutated_base_passes(usdc: bool, sponsored: bool) -> None:
    base = _base(random.Random(SEED), usdc, sponsored)
    _validate_instruction_allowlist(*_compile(base, [_payment(base)]))
