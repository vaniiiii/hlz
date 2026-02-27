# HTTP Client

The SDK client provides typed access to all Hyperliquid HTTP endpoints.

## Creating a Client

```zig
const Client = hlz.hypercore.client.Client;

// Mainnet
var client = Client.mainnet(allocator);
defer client.deinit();

// Testnet
var client = Client.testnet(allocator);
defer client.deinit();
```

## Info Endpoints (No Auth)

All info endpoints are public. They return `Parsed(T)` — call `.deinit()` when done.

```zig
// All mid prices
var mids = try client.getAllMids(null);
defer mids.deinit();

// Market metadata + asset contexts
var meta = try client.getMetaAndAssetCtxs(null);
defer meta.deinit();

// Account state
var state = try client.getClearinghouseState(address, null);
defer state.deinit();

// Open orders
var orders = try client.getOpenOrders(address, null);
defer orders.deinit();

// User fills
var fills = try client.getUserFills(address, null);
defer fills.deinit();

// L2 order book
var book = try client.getL2Book("BTC", null);
defer book.deinit();

// Candle data
var candles = try client.getCandleSnapshot("BTC", "1h", null);
defer candles.deinit();
```

### Full List of Info Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `getAllMids` | Raw JSON | All mid prices (dynamic keys) |
| `getMeta` | `Meta` | Market metadata |
| `getMetaAndAssetCtxs` | `MetaAndAssetCtxs` | Meta + live context |
| `getClearinghouseState` | `ClearinghouseState` | Account margin state |
| `getOpenOrders` | `[]OpenOrder` | User's open orders |
| `getUserFills` | `[]Fill` | User's recent fills |
| `getOrderStatus` | `OrderStatus` | Status by OID |
| `getL2Book` | `L2Book` | Order book snapshot |
| `getCandleSnapshot` | `[]Candle` | OHLCV candles |
| `getFundingHistory` | `[]FundingEntry` | Funding rate history |
| `getSpotMeta` | `SpotMeta` | Spot market metadata |
| `getSpotClearinghouseState` | `SpotClearinghouseState` | Spot balances |
| `getPerpDexs` | `[]PerpDex` | HIP-3 DEX list |
| `getUserFees` | `UserFees` | Fee rates |
| `getReferral` | `Referral` | Referral info |
| `getSubAccounts` | `[]SubAccount` | Sub-accounts |
| `getPerpsAtOpenInterest` | Raw JSON | OI data |

## Exchange Endpoints (Signed)

Exchange endpoints require a `Signer` and produce EIP-712 signatures.

```zig
const signer = try Signer.fromHex("your_key");
const nonce = @as(u64, @intCast(std.time.milliTimestamp()));

// Place order
var result = try client.place(signer, batch_order, nonce, null, null);
defer result.deinit();

// Cancel by OID
var result = try client.cancel(signer, cancel_request, nonce, null, null);
defer result.deinit();

// Cancel by CLOID
var result = try client.cancelByCloid(signer, cancel_request, nonce, null, null);
defer result.deinit();

// Modify order
var result = try client.modify(signer, modify_request, nonce, null, null);
defer result.deinit();

// Set leverage
var result = try client.updateLeverage(signer, asset, leverage, nonce, null, null);
defer result.deinit();

// Send USDC
var result = try client.usdSend(signer, send_request, nonce);
defer result.deinit();
```

### Full List of Exchange Methods

| Method | Description |
|--------|-------------|
| `place` | Place order(s) |
| `cancel` | Cancel by OID |
| `cancelByCloid` | Cancel by client order ID |
| `modify` | Modify existing order |
| `batchModify` | Modify multiple orders |
| `scheduleCancel` | Schedule future cancellation |
| `updateLeverage` | Set leverage |
| `updateIsolatedMargin` | Adjust isolated margin |
| `usdSend` | Send USDC |
| `spotSend` | Send spot tokens |
| `sendAsset` | Send between contexts |
| `approveAgent` | Approve API wallet |

## Raw vs Typed

For `--json` passthrough, use raw methods. For typed access, use `get*` methods:

```zig
// Typed (returns parsed struct)
var typed = try client.getClearinghouseState(addr, null);
defer typed.deinit();
// typed.value.marginSummary.accountValue...

// Raw (returns HTTP body as string)
var raw = try client.clearinghouseState(addr, null);
defer raw.deinit();
// raw.body is the JSON string
```

**Rule**: Never fetch both. Branch on output format early.
