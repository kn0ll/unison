# Unison WASM Demo: Price Calculator

This demo showcases the **"one-program fullstack"** vision of Unison + WebAssembly.

The same `calculatePrice` function runs in:
- **Browser** — Compiled to WASM, instant UI updates
- **Server** — Same WASM module in Node.js, authoritative calculation

## Why This Matters

| Traditional Apps | Unison WASM |
|------------------|-------------|
| Frontend: JavaScript | Same Unison code |
| Backend: Python/Go/Java | Same Unison code |
| Keep them in sync: 🙏 | Literally impossible to drift |

## Quick Start

```bash
# Install dependencies
npm install

# Build WASM + TypeScript and start server
npm run dev

# Open in browser
open http://localhost:3001
```

## Demo Features

1. **Instant Price Calculation** — Move the slider, see prices update instantly (WASM)
2. **Server Verification** — Click "Verify" to confirm server agrees (same WASM)
3. **Drift Mode** — Toggle ON to simulate what happens with duplicated code
4. **Foreign Calls (IO)** — `IO.printNat` logs to browser console AND server console

## Foreign Calls Demo

The demo uses `calculatePriceWithLog` which calls `IO.printNat` — a foreign function:

```unison
-- This Unison code calls a JS function (console.log)
calculatePriceWithLog : Nat ->{IO} Nat
calculatePriceWithLog quantity =
  price = calculatePrice quantity
  printLine (Nat.toText price)  -- Foreign call!
  price
```

Open your browser's developer tools (Console tab) and you'll see:
```
[Unison] Price calculated: $45.00 (4500 cents)
```

The same message appears in the server terminal when you click "Verify with Server".

This demonstrates that **abilities (IO effects)** work seamlessly from WASM to JS.

### Supported Foreign Functions

| Unison Function | JS Implementation | Notes |
|-----------------|-------------------|-------|
| `IO.printNat` | `console.log(value)` | ✅ Working |
| `IO.printLine` | `console.log(text)` | ✅ Working (pointer only) |
| `IO.systemTime` | `Date.now() * 1000` | ✅ Returns microseconds |
| `IO.delay` | Stub (logs only) | ⏳ Full async requires yield/resume |

## Project Structure

```
demo/
├── index.html       # Demo page
├── demo.ts          # Browser TypeScript
├── server.ts        # Node.js Express server
├── build-wasm.sh    # WASM build script
├── src/
│   ├── pricing.u    # THE SHARED UNISON CODE
│   └── server.u     # Unison HTTP server (placeholder)
├── dist/            # Build output
│   ├── demo.js      # Compiled browser JS
│   ├── server.js    # Compiled server JS
│   ├── pricing.wat  # Compiled WAT
│   └── pricing.wasm # Compiled WASM binary
├── package.json
└── tsconfig.json
```

## The Shared Code

```unison
-- pricing.u — runs in BOTH browser and server

calculatePrice : Nat -> Nat
calculatePrice quantity =
  unitPrice = 1000  -- $10.00 in cents
  subtotal = quantity * unitPrice
  discount = if quantity >= 5 then subtotal / 10 else 0
  subtotal - discount
```

## Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Build everything and start Express server |
| `npm run build` | Build WASM + TypeScript |
| `npm run build:wasm` | Compile Unison to WAT → WASM |
| `npm run build:ts` | Compile TypeScript only |
| `npm run server` | Start the Express server |
| `npm run serve:static` | Serve static files only (no API) |

## API Endpoints

The Express server provides these endpoints:

```bash
# Get price for quantity (uses WASM)
GET /api/price?qty=5
# → { quantity: 5, price: 4500, formatted: { price: "$45.00" }, source: "unison-wasm" }

# Get price with simulated drift (uses different JS logic)
GET /api/price-drift?qty=5
# → { quantity: 5, price: 4250, source: "javascript-drift" }

# Health check
GET /api/health
# → { status: "ok", wasmLoaded: true }
```

## Development

### Prerequisites

- Node.js 18+
- npm
- `wabt` package for WASM compilation: `sudo apt-get install wabt`
- (Optional) Unison WASM compiler for compiling `.u` files

### Build Process

```bash
# 1. Build WASM from Unison code
npm run build:wasm
# This runs build-wasm.sh which:
#   - Generates pricing.wat (reference implementation)
#   - Converts to pricing.wasm using wat2wasm

# 2. Build TypeScript
npm run build:ts

# 3. Start server
npm run server
```

### How It Works

1. **Browser loads `pricing.wasm`** and calls `calculatePrice()` on slider change
2. **Server loads the same `pricing.wasm`** for the `/api/price` endpoint
3. **Both compute identical results** because they run the same code
4. **Drift mode** uses a different JS implementation (15% discount) to show what goes wrong

## Browser Dev Tools

Open the browser console and use:

```javascript
// Calculate price for 10 items
unisonRuntime.calculatePrice(10)  // → 9000

// Calculate discount for 10 items
unisonRuntime.calculateDiscount(10)  // → 1000

// Access the WASM runtime
unisonRuntime.runtime.exports  // → { calculatePrice, calculateDiscount, ... }
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3001` | Server port |

```bash
# Run on a different port
PORT=8080 npm run server
```

## License

MIT
