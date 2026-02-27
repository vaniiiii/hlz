# Key Management

hlz stores keys in encrypted keystores, compatible with Foundry's format.

## Commands

### `hlz keys new <NAME>`

Generate a new secp256k1 private key and store it encrypted.

```bash
hlz keys new trading
# Enter password: ****
# Address: 0x1234...abcd
# Stored in: ~/.hlz/keys/trading
```

### `hlz keys import <NAME>`

Import an existing private key.

```bash
hlz keys import trading --private-key 0xYOUR_KEY
# Enter password: ****
```

### `hlz keys ls`

List all stored keys.

```bash
hlz keys ls
# NAME      ADDRESS                                    DEFAULT
# trading   0x1234...abcd                              ✓
# backup    0x5678...efgh
```

### `hlz keys default <NAME>`

Set the default key used when no `--key-name` is specified.

```bash
hlz keys default trading
```

### `hlz keys export <NAME>`

Export the decrypted private key (use with caution).

```bash
hlz keys export trading
# Enter password: ****
# 0xYOUR_PRIVATE_KEY
```

### `hlz keys rm <NAME>`

Remove a stored key.

```bash
hlz keys rm backup
```

## Security

- Keys are encrypted with AES-128-CTR + scrypt KDF
- Password is never stored
- Use `HL_PASSWORD` env var for automation (be careful with shell history)
- Consider `hlz approve-agent <ADDR>` for API wallets with limited permissions
