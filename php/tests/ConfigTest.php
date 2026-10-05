<?php

declare(strict_types=1);

namespace PayKit\Tests;

use PayKit\Config;
use PayKit\Exception\ConfigurationException;
use PayKit\Exception\DemoSignerOnMainnetException;
use PayKit\Exception\InvalidKeyException;
use PayKit\PayCore\Network;
use PayKit\Operator;
use PayKit\Protocol;
use PayKit\Signer;
use PayKit\PayCore\Stablecoin;
use PHPUnit\Framework\TestCase;

final class ConfigTest extends TestCase
{
    private const ENV_NAMES = [
        'NETWORK', 'RPC_URL', 'ACCEPT', 'STABLECOINS', 'PREFLIGHT',
        'OPERATOR_RECIPIENT', 'OPERATOR_KEY', 'MPP_REALM',
        'MPP_CHALLENGE_BINDING_SECRET', 'MPP_EXPIRES_IN', 'X402_FACILITATOR_URL',
    ];

    protected function tearDown(): void
    {
        foreach (self::ENV_NAMES as $name) {
            putenv("PAY_KIT_{$name}");
            putenv("ACME_{$name}");
        }
    }

    public function testFromEnvWithNoVarsUsesDefaults(): void
    {
        putenv('PAY_KIT_PREFLIGHT=false');
        $cfg = Config::fromEnv();
        $this->assertEquals(new Config(preflight: false), $cfg);
        $this->assertSame(Network::SolanaLocalnet, $cfg->network);
        $this->assertSame([Protocol::X402, Protocol::Mpp], $cfg->accept);
        $this->assertSame([Stablecoin::Usdc], $cfg->stablecoins);
        $this->assertSame(120, $cfg->mpp->expiresIn);
        $this->assertTrue($cfg->operator->signer?->isDemo());
    }

    public function testFromEnvReadsEveryVar(): void
    {
        $sgn = Signer::generate();
        putenv('PAY_KIT_NETWORK=solana_devnet');
        putenv('PAY_KIT_RPC_URL=https://rpc.example.com');
        putenv('PAY_KIT_ACCEPT=mpp, x402');
        putenv('PAY_KIT_STABLECOINS=USDT,USDC');
        putenv('PAY_KIT_PREFLIGHT=off');
        putenv('PAY_KIT_OPERATOR_RECIPIENT=CustomRecipient');
        putenv('PAY_KIT_OPERATOR_KEY=' . bin2hex($sgn->secretKey()));
        putenv('PAY_KIT_MPP_REALM=Realm');
        putenv('PAY_KIT_MPP_CHALLENGE_BINDING_SECRET=secret');
        putenv('PAY_KIT_MPP_EXPIRES_IN=0');
        putenv('PAY_KIT_X402_FACILITATOR_URL=https://facilitator.example.com');

        $cfg = Config::fromEnv();

        $this->assertSame(Network::SolanaDevnet, $cfg->network);
        $this->assertSame('https://rpc.example.com', $cfg->rpcUrl);
        $this->assertSame([Protocol::Mpp, Protocol::X402], $cfg->accept);
        $this->assertSame([Stablecoin::Usdt, Stablecoin::Usdc], $cfg->stablecoins);
        $this->assertFalse($cfg->preflight);
        $this->assertSame('CustomRecipient', $cfg->effectiveRecipient());
        $this->assertSame($sgn->pubkey(), $cfg->operator->signer?->pubkey());
        $this->assertSame('Realm', $cfg->mpp->realm);
        $this->assertSame('secret', $cfg->mpp->challengeBindingSecret);
        $this->assertSame(0, $cfg->mpp->expiresIn);
        $this->assertSame('https://facilitator.example.com', $cfg->x402->facilitatorUrl);
    }

    public function testFromEnvHonoursCustomPrefix(): void
    {
        putenv('ACME_NETWORK=solana_devnet');
        putenv('ACME_PREFLIGHT=false');
        putenv('PAY_KIT_NETWORK=solana_mainnet');
        $this->assertSame(Network::SolanaDevnet, Config::fromEnv('ACME_')->network);
    }

    /**
     * @return array<string, array{string, string}>
     */
    public static function malformedEnvProvider(): array
    {
        return [
            'network'     => ['NETWORK', 'solana_testnet'],
            'accept'      => ['ACCEPT', 'x402,bogus'],
            'stablecoins' => ['STABLECOINS', 'USDC,DOGE'],
            'preflight'   => ['PREFLIGHT', 'maybe'],
            'expires_in'  => ['MPP_EXPIRES_IN', '2m'],
        ];
    }

    #[\PHPUnit\Framework\Attributes\DataProvider('malformedEnvProvider')]
    public function testFromEnvRejectsMalformedValues(string $name, string $value): void
    {
        putenv('PAY_KIT_MPP_CHALLENGE_BINDING_SECRET=secret');
        putenv("PAY_KIT_{$name}={$value}");
        $this->expectException(ConfigurationException::class);
        Config::fromEnv();
    }

    /**
     * @return array<string, array{string, class-string<\Throwable>}>
     */
    public static function signerEnvProvider(): array
    {
        return [
            'malformed key'          => ['PAY_KIT_OPERATOR_KEY=not-a-key', InvalidKeyException::class],
            'mainnet without a key'  => ['PAY_KIT_NETWORK=solana_mainnet', DemoSignerOnMainnetException::class],
        ];
    }

    /**
     * @param class-string<\Throwable> $exception
     */
    #[\PHPUnit\Framework\Attributes\DataProvider('signerEnvProvider')]
    public function testFromEnvRejectsBadSigner(string $assignment, string $exception): void
    {
        putenv('PAY_KIT_PREFLIGHT=false');
        putenv($assignment);
        $this->expectException($exception);
        Config::fromEnv();
    }

    public function testZeroConfigUsesLocalnetDefaultsAndDemoSigner(): void
    {
        $cfg = new Config(preflight: false);
        $this->assertSame(Network::SolanaLocalnet, $cfg->network);
        $this->assertSame('https://402.surfnet.dev:8899', $cfg->rpcUrl);
        $this->assertTrue($cfg->operator->signer?->isDemo());
        // Recipient cascades to signer->pubkey().
        $this->assertSame(Signer::demo()->pubkey(), $cfg->effectiveRecipient());
    }

    public function testDevnetAndMainnetDefaults(): void
    {
        $cfg = new Config(network: Network::SolanaDevnet, preflight: false);
        $this->assertSame('https://api.devnet.solana.com', $cfg->rpcUrl);
    }

    public function testCustomRpcUrlHonoured(): void
    {
        $cfg = new Config(
            network: Network::SolanaDevnet,
            rpcUrl: 'https://my-helius.example.com',
            preflight: false,
        );
        $this->assertSame('https://my-helius.example.com', $cfg->rpcUrl);
    }

    public function testMainnetWithDemoSignerRejected(): void
    {
        $this->expectException(DemoSignerOnMainnetException::class);
        new Config(network: Network::SolanaMainnet, preflight: false);
    }

    public function testEmptyAcceptRejected(): void
    {
        $this->expectException(ConfigurationException::class);
        new Config(accept: [], preflight: false);
    }

    public function testStablecoinAndAcceptOrderPreserved(): void
    {
        $cfg = new Config(
            accept:      [Protocol::Mpp, Protocol::X402],
            stablecoins: [Stablecoin::Usdt, Stablecoin::Usdc],
            preflight:   false,
        );
        $this->assertSame(Protocol::Mpp, $cfg->accept[0]);
        $this->assertSame(Stablecoin::Usdt, $cfg->stablecoins[0]);
    }

    public function testExplicitOperatorOverridesDefaults(): void
    {
        $sgn = Signer::generate();
        $cfg = new Config(
            network: Network::SolanaDevnet,
            operator: new Operator(recipient: 'CustomRecipient', signer: $sgn, feePayer: false),
            preflight: false,
        );
        $this->assertSame('CustomRecipient', $cfg->effectiveRecipient());
        $this->assertSame($sgn->pubkey(), $cfg->operator->signer?->pubkey());
        $this->assertFalse($cfg->operator->feePayer);
    }
    public function testEffectiveX402SignerFallsBackToOperatorSigner(): void
    {
        $sgn = Signer::generate();
        $cfg = new Config(
            network: Network::SolanaDevnet,
            operator: new Operator(recipient: Signer::generate()->pubkey(), signer: $sgn, feePayer: true),
            preflight: false,
        );
        $this->assertSame($sgn->pubkey(), $cfg->effectiveX402Signer()?->pubkey());
    }

    public function testWithMppReturnsCopy(): void
    {
        $cfg = new Config(network: Network::SolanaDevnet, preflight: false);
        $newMpp = new \PayKit\Protocols\Mpp\MppConfig(realm: 'NewRealm', challengeBindingSecret: 'abc');
        $next = $cfg->withMpp($newMpp);
        $this->assertSame('NewRealm', $next->mpp->realm);
        $this->assertSame('abc', $next->mpp->challengeBindingSecret);
        $this->assertSame($cfg->network, $next->network);
    }

    public function testInvalidAcceptEntryRejected(): void
    {
        $this->expectException(\PayKit\Exception\ConfigurationException::class);
        new Config(accept: ['not-a-protocol-enum'], preflight: false);
    }

    public function testInvalidStablecoinEntryRejected(): void
    {
        $this->expectException(\PayKit\Exception\ConfigurationException::class);
        new Config(stablecoins: ['not-a-stablecoin-enum'], preflight: false);
    }

    public function testEmptyStablecoinsRejected(): void
    {
        $this->expectException(ConfigurationException::class);
        new Config(
            network: Network::SolanaDevnet,
            stablecoins: [],
            operator: new Operator(recipient: Signer::generate()->pubkey()),
            preflight: false,
            mpp: new \PayKit\Protocols\Mpp\MppConfig(challengeBindingSecret: 'x'),
        );
    }
}
