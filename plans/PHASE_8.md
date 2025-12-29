# Phase 8: Integration Demo — Implementation Plan

## Overview

**Goal:** Demonstrate the full "one-program fullstack" vision with a working demo where the same Unison code runs on both server (native) and browser (WASM).

**Key Insight:** The user must **see and feel** why shared code matters — not just technically work.

**Deliverable:** A Price Calculator demo that:
- Computes prices **instantly** in the browser (WASM)
- Verifies prices on the **server** (native Unison)
- Shows they **always match** because it's the same code
- Optionally demonstrates what **goes wrong** with duplicated code

---

## Why Price Calculator (Not Counter)

| Demo | User Experience | Demonstrates Value? |
|------|-----------------|---------------------|
| Counter | "It counts... cool?" | ❌ Not compelling |
| **Price Calculator** | "Browser and server agree! No checkout surprises!" | ✅ Real-world value |

The user experiences the **benefit** of shared code, not just its existence.

---

## Demo User Experience

### What the User Sees

```
┌─────────────────────────────────────────────────────────────────┐
│              Unison WASM Demo: Price Calculator                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Quantity:  [────●────] 5                                       │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Unit Price:      $10.00                                 │   │
│  │  Subtotal:        $50.00                                 │   │
│  │  Bulk Discount:   -$5.00  (10% off 5+ items)            │   │
│  │  ───────────────────────────────────────────────────    │   │
│  │  Total:           $45.00  ⚡ calculated in WASM          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  [Verify with Server]                                            │
│                                                                  │
│  ✅ Server confirms: $45.00                                     │
│     Both computed by the SAME Unison function!                  │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  📝 The shared code (runs in browser AND server):        │   │
│  │                                                          │   │
│  │    calculatePrice : Nat -> Dollars                       │   │
│  │    calculatePrice qty =                                  │   │
│  │      base = qty * 1000  -- cents                        │   │
│  │      discount = if qty >= 5 then base / 10 else 0       │   │
│  │      base - discount                                    │   │
│  │                                                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ⚠️ Toggle "Drift Mode" to simulate duplicated code:     │   │
│  │  [  OFF  |  ON  ]                                        │   │
│  │                                                          │   │
│  │  In drift mode, the "server" uses slightly different    │   │
│  │  logic — like real apps with JS frontend + Python backend│   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The "Aha!" Moments

| Step | What User Does | What They See | Reaction |
|------|----------------|---------------|----------|
| 1 | Adjust quantity slider | Price updates **instantly** | "Fast!" |
| 2 | Click "Verify with Server" | Server returns **same price** | "They match!" |
| 3 | See the Unison code | ONE function for both | "Oh, it's literally the same code!" |
| 4 | Toggle "Drift Mode" ON | Prices **diverge** | "This is the bug we're avoiding!" |
| 5 | Toggle "Drift Mode" OFF | Prices match again | "Unison prevents this." |

---

## Architecture

### High-Level Demo Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Browser                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    WASM Module                                │   │
│  │  ┌────────────────────────────────────────────────────┐     │   │
│  │  │ calculatePrice : Nat -> Nat                         │     │   │
│  │  │ (SAME code as server, compiled to WASM)            │     │   │
│  │  └────────────────────────────────────────────────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
│              │                              │                        │
│              ▼                              ▼                        │
│  ┌──────────────────┐          ┌──────────────────────────┐        │
│  │ Instant UI update│          │ fetch('/api/price?qty=5')│        │
│  │ (no server call) │          │ async yield → resume     │        │
│  └──────────────────┘          └──────────────────────────┘        │
│                                             │                        │
└─────────────────────────────────────────────│────────────────────────┘
                                              │
                                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│                           Server                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                Native Unison Runtime                          │    │
│  │  ┌────────────────────────────────────────────────────┐      │    │
│  │  │ calculatePrice : Nat -> Nat                         │      │    │
│  │  │ (SAME code as browser, runs natively)              │      │    │
│  │  └────────────────────────────────────────────────────┘      │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Why This Works

| Concern | Traditional Apps | Unison WASM |
|---------|-----------------|-------------|
| Instant feedback | Call server (slow) or duplicate logic (risky) | Same code runs locally |
| Server validation | Must reimplement in backend language | Same code runs natively |
| Keeping them in sync | Hope + tests + prayer | Literally the same function |

---

## The Shared Unison Code

```unison
-- pricing.u
-- This file runs on BOTH server and browser

-- Price in cents (to avoid floating point issues)
type Dollars = Dollars Nat

Dollars.cents : Dollars -> Nat
Dollars.cents (Dollars c) = c

Dollars.fromCents : Nat -> Dollars
Dollars.fromCents c = Dollars c

Dollars.format : Dollars -> Text
Dollars.format (Dollars cents) =
  dollars = cents / 100
  remainder = cents `mod` 100
  "$" ++ Nat.toText dollars ++ "." ++
    (if remainder < 10 then "0" else "") ++ Nat.toText remainder

-- THE SHARED PRICING LOGIC
-- This function runs in:
--   - Browser (compiled to WASM, instant UI updates)
--   - Server (native Unison, authoritative calculation)
calculatePrice : Nat -> Dollars
calculatePrice quantity =
  unitPrice = 1000  -- $10.00 in cents
  subtotal = quantity * unitPrice
  discount =
    if quantity >= 5
    then subtotal / 10  -- 10% bulk discount
    else 0
  Dollars.fromCents (subtotal - discount)

-- Get just the discount amount
calculateDiscount : Nat -> Dollars
calculateDiscount quantity =
  unitPrice = 1000
  subtotal = quantity * unitPrice
  if quantity >= 5
  then Dollars.fromCents (subtotal / 10)
  else Dollars.fromCents 0
```

---

## Demo Application Specification

### Features

1. **Quantity Slider** — Adjust quantity, see price update instantly (WASM)
2. **Price Breakdown** — Shows subtotal, discount, and total
3. **Server Verification** — Button to check server agrees (async fetch)
4. **Code Display** — Shows the actual Unison function
5. **Drift Mode Toggle** — Simulates what happens with duplicated code

### HTML Demo Page

```html
<!-- demo/index.html -->
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Unison WASM Demo: Price Calculator</title>
  <style>
    :root {
      --bg: #1a1a2e;
      --card: #16213e;
      --accent: #e94560;
      --text: #eee;
      --muted: #888;
      --success: #4ade80;
      --warning: #fbbf24;
    }

    * { box-sizing: border-box; }

    body {
      font-family: 'SF Mono', 'Fira Code', monospace;
      background: var(--bg);
      color: var(--text);
      max-width: 700px;
      margin: 0 auto;
      padding: 2rem;
      line-height: 1.6;
    }

    h1 {
      color: var(--accent);
      font-size: 1.5rem;
      margin-bottom: 0.5rem;
    }

    .subtitle {
      color: var(--muted);
      font-size: 0.9rem;
      margin-bottom: 2rem;
    }

    .card {
      background: var(--card);
      border-radius: 12px;
      padding: 1.5rem;
      margin-bottom: 1.5rem;
    }

    .slider-container {
      display: flex;
      align-items: center;
      gap: 1rem;
      margin-bottom: 1rem;
    }

    input[type="range"] {
      flex: 1;
      accent-color: var(--accent);
    }

    .quantity-display {
      font-size: 2rem;
      font-weight: bold;
      color: var(--accent);
      min-width: 3ch;
      text-align: right;
    }

    .price-row {
      display: flex;
      justify-content: space-between;
      padding: 0.5rem 0;
    }

    .price-row.total {
      border-top: 1px solid var(--muted);
      margin-top: 0.5rem;
      padding-top: 1rem;
      font-size: 1.2rem;
      font-weight: bold;
    }

    .price-row .label { color: var(--muted); }
    .price-row .value { color: var(--text); }
    .price-row.discount .value { color: var(--success); }
    .price-row.total .value { color: var(--accent); }

    .wasm-badge {
      font-size: 0.7rem;
      background: var(--accent);
      color: white;
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      margin-left: 0.5rem;
    }

    button {
      background: var(--accent);
      color: white;
      border: none;
      padding: 0.75rem 1.5rem;
      border-radius: 8px;
      font-family: inherit;
      font-size: 1rem;
      cursor: pointer;
      transition: opacity 0.2s;
    }

    button:hover { opacity: 0.9; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }

    .server-result {
      margin-top: 1rem;
      padding: 1rem;
      border-radius: 8px;
      background: rgba(74, 222, 128, 0.1);
      border: 1px solid var(--success);
    }

    .server-result.error {
      background: rgba(239, 68, 68, 0.1);
      border-color: #ef4444;
    }

    .server-result.drift {
      background: rgba(251, 191, 36, 0.1);
      border-color: var(--warning);
    }

    .code-block {
      background: #0d1117;
      border-radius: 8px;
      padding: 1rem;
      font-size: 0.85rem;
      overflow-x: auto;
    }

    .code-block .keyword { color: #ff7b72; }
    .code-block .function { color: #d2a8ff; }
    .code-block .number { color: #79c0ff; }
    .code-block .comment { color: #8b949e; }

    .toggle-container {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .toggle {
      position: relative;
      width: 60px;
      height: 30px;
      background: #333;
      border-radius: 15px;
      cursor: pointer;
      transition: background 0.3s;
    }

    .toggle.on { background: var(--warning); }

    .toggle::after {
      content: '';
      position: absolute;
      width: 26px;
      height: 26px;
      background: white;
      border-radius: 50%;
      top: 2px;
      left: 2px;
      transition: left 0.3s;
    }

    .toggle.on::after { left: 32px; }

    .warning-text {
      color: var(--warning);
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <h1>⚡ Unison WASM Demo</h1>
  <p class="subtitle">Same code runs in browser (WASM) and server (native)</p>

  <div class="card">
    <h2>Price Calculator</h2>

    <div class="slider-container">
      <label>Quantity:</label>
      <input type="range" id="quantity" min="1" max="20" value="5">
      <span class="quantity-display" id="qty-display">5</span>
    </div>

    <div class="price-breakdown">
      <div class="price-row">
        <span class="label">Unit Price</span>
        <span class="value">$10.00</span>
      </div>
      <div class="price-row">
        <span class="label">Subtotal</span>
        <span class="value" id="subtotal">$50.00</span>
      </div>
      <div class="price-row discount">
        <span class="label">Bulk Discount (10% off 5+)</span>
        <span class="value" id="discount">-$5.00</span>
      </div>
      <div class="price-row total">
        <span class="label">Total <span class="wasm-badge">WASM</span></span>
        <span class="value" id="total">$45.00</span>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>Server Verification</h2>
    <button id="verify-btn">Verify with Server</button>
    <div class="server-result" id="server-result" style="display: none;">
      <span id="server-message"></span>
    </div>
  </div>

  <div class="card">
    <h2>The Shared Code</h2>
    <p style="color: var(--muted); font-size: 0.9rem; margin-bottom: 1rem;">
      This exact function runs in both environments:
    </p>
    <div class="code-block">
<span class="function">calculatePrice</span> : <span class="keyword">Nat</span> -> <span class="keyword">Nat</span>
<span class="function">calculatePrice</span> quantity =
  <span class="keyword">let</span> unitPrice = <span class="number">1000</span>  <span class="comment">-- $10.00 in cents</span>
  <span class="keyword">let</span> subtotal = quantity * unitPrice
  <span class="keyword">let</span> discount =
    <span class="keyword">if</span> quantity >= <span class="number">5</span>
    <span class="keyword">then</span> subtotal / <span class="number">10</span>  <span class="comment">-- 10% bulk discount</span>
    <span class="keyword">else</span> <span class="number">0</span>
  subtotal - discount
    </div>
  </div>

  <div class="card">
    <h2>⚠️ Drift Mode</h2>
    <p style="color: var(--muted); font-size: 0.9rem; margin-bottom: 1rem;">
      Simulate what happens when frontend and backend have different code:
    </p>
    <div class="toggle-container">
      <div class="toggle" id="drift-toggle"></div>
      <span id="drift-label">OFF — Using shared Unison code</span>
    </div>
    <p class="warning-text" id="drift-warning" style="display: none; margin-top: 1rem;">
      ⚠️ Drift mode: Server uses 15% discount instead of 10%.<br>
      This simulates the bugs that happen with duplicated code!
    </p>
  </div>

  <script type="module" src="./demo.js"></script>
</body>
</html>
```

---

## Implementation Tasks

### Task 8.1: Demo Project Structure

**Create demo project scaffold:**

```
unison-wasm/demo/
├── index.html          # Demo page (above)
├── demo.ts             # TypeScript glue code
├── src/                # Server-side code
│   └── pricing.u       # Shared Unison pricing logic
├── bin/                # Server-side code
│   └── server.u        # HTTP server
├── package.json        # Dependencies and scripts
├── tsconfig.json       # TypeScript config
└── dist/               # Build output
    ├── pricing.wasm    # Compiled WASM
    └── pricing.d.ts    # Generated types
```

**Exit criterion:** Project structure exists and builds.

---

### Task 8.2: Pricing Logic (Shared Unison)

**Implement the pricing calculation that runs in both environments:**

```unison
-- pricing.u

-- Calculate total price in cents
calculatePrice : Nat -> Nat
calculatePrice quantity =
  unitPrice = 1000  -- $10.00 in cents
  subtotal = quantity * unitPrice
  discount = if quantity >= 5 then subtotal / 10 else 0
  subtotal - discount

-- Calculate just the discount
calculateDiscount : Nat -> Nat
calculateDiscount quantity =
  unitPrice = 1000
  subtotal = quantity * unitPrice
  if quantity >= 5 then subtotal / 10 else 0

-- Calculate subtotal
calculateSubtotal : Nat -> Nat
calculateSubtotal quantity = quantity * 1000
```

**WASM module exports:**
- `calculatePrice(qty: i64) -> i64` — Total price in cents
- `calculateDiscount(qty: i64) -> i64` — Discount in cents
- `calculateSubtotal(qty: i64) -> i64` — Subtotal before discount

**Exit criterion:** Pricing compiles to WASM and returns correct values.

---

### Task 8.3: Demo JavaScript/TypeScript

**Create the interactive demo code:**

```typescript
// demo/demo.ts
import { UnisonRuntime } from '@unison/wasm-runtime';

let runtime: UnisonRuntime;
let driftMode = false;

async function init() {
  runtime = new UnisonRuntime();

  // Load the compiled WASM module
  const response = await fetch('./dist/pricing.wasm');
  const bytes = await response.arrayBuffer();
  await runtime.loadWasm(bytes);

  // Wire up UI
  const slider = document.getElementById('quantity') as HTMLInputElement;
  const verifyBtn = document.getElementById('verify-btn') as HTMLButtonElement;
  const driftToggle = document.getElementById('drift-toggle')!;

  slider.addEventListener('input', () => updatePrice());
  verifyBtn.addEventListener('click', () => verifyWithServer());
  driftToggle.addEventListener('click', () => toggleDrift());

  // Expose runtime to dev tools
  runtime.exposeToDevTools('unisonRuntime');

  // Initial calculation
  updatePrice();
  console.log('✅ Unison WASM demo initialized!');
}

function updatePrice() {
  const qty = parseInt((document.getElementById('quantity') as HTMLInputElement).value);

  // Call WASM functions
  const subtotal = Number(runtime.callBigInt('calculateSubtotal', BigInt(qty)));
  const discount = Number(runtime.callBigInt('calculateDiscount', BigInt(qty)));
  const total = Number(runtime.callBigInt('calculatePrice', BigInt(qty)));

  // Update UI
  document.getElementById('qty-display')!.textContent = String(qty);
  document.getElementById('subtotal')!.textContent = formatCents(subtotal);
  document.getElementById('discount')!.textContent = discount > 0 ? `-${formatCents(discount)}` : '$0.00';
  document.getElementById('total')!.textContent = formatCents(total);

  // Hide previous server result
  document.getElementById('server-result')!.style.display = 'none';
}

async function verifyWithServer() {
  const qty = parseInt((document.getElementById('quantity') as HTMLInputElement).value);
  const clientPrice = Number(runtime.callBigInt('calculatePrice', BigInt(qty)));

  const btn = document.getElementById('verify-btn') as HTMLButtonElement;
  btn.disabled = true;
  btn.textContent = 'Verifying...';

  try {
    // In real demo, this would be: await runtime.run('fetchServerPrice', qty)
    // For now, simulate with setTimeout
    await new Promise(resolve => setTimeout(resolve, 500));

    // Simulate server response
    let serverPrice = clientPrice;  // Same code = same result

    if (driftMode) {
      // Simulate "drift" — server has different logic
      const subtotal = qty * 1000;
      const discount = qty >= 5 ? Math.floor(subtotal * 0.15) : 0;  // 15% instead of 10%!
      serverPrice = subtotal - discount;
    }

    const resultDiv = document.getElementById('server-result')!;
    const messageSpan = document.getElementById('server-message')!;
    resultDiv.style.display = 'block';

    if (serverPrice === clientPrice) {
      resultDiv.className = 'server-result';
      messageSpan.innerHTML = `✅ <strong>Server confirms: ${formatCents(serverPrice)}</strong><br>
        <span style="color: var(--muted)">Both computed by the SAME Unison function!</span>`;
    } else {
      resultDiv.className = 'server-result drift';
      messageSpan.innerHTML = `⚠️ <strong>Price mismatch!</strong><br>
        Browser: ${formatCents(clientPrice)}<br>
        Server: ${formatCents(serverPrice)}<br>
        <span style="color: var(--warning)">This is what happens with duplicated code!</span>`;
    }
  } finally {
    btn.disabled = false;
    btn.textContent = 'Verify with Server';
  }
}

function toggleDrift() {
  driftMode = !driftMode;
  const toggle = document.getElementById('drift-toggle')!;
  const label = document.getElementById('drift-label')!;
  const warning = document.getElementById('drift-warning')!;

  toggle.classList.toggle('on', driftMode);
  label.textContent = driftMode
    ? 'ON — Simulating duplicated code'
    : 'OFF — Using shared Unison code';
  warning.style.display = driftMode ? 'block' : 'none';

  // Hide server result when toggling
  document.getElementById('server-result')!.style.display = 'none';
}

function formatCents(cents: number): string {
  const dollars = Math.floor(cents / 100);
  const remainder = cents % 100;
  return `$${dollars}.${remainder.toString().padStart(2, '0')}`;
}

init().catch(console.error);
```

**Exit criterion:** Demo is interactive with slider and server verification.

---

### Task 8.4: Server Implementation

**Create server that uses the same Unison code:**

For the initial demo, we'll simulate the server in JavaScript. In a full implementation, this would be a native Unison HTTP server using UCM.

```typescript
// demo/server.ts (Node.js)
import express from 'express';
import { UnisonRuntime } from '@unison/wasm-runtime';
import { readFileSync } from 'fs';

const app = express();

// Load the SAME WASM module
const wasmBytes = readFileSync('./dist/pricing.wasm');
const runtime = new UnisonRuntime();

app.get('/api/price', async (req, res) => {
  await runtime.loadWasm(wasmBytes);

  const qty = parseInt(req.query.qty as string) || 1;
  const price = runtime.callBigInt('calculatePrice', BigInt(qty));

  res.json({
    quantity: qty,
    price: Number(price),
    formatted: formatCents(Number(price))
  });
});

app.listen(8080, () => {
  console.log('Server running on http://localhost:8080');
  console.log('Using the SAME Unison code as the browser!');
});
```

**Exit criterion:** Server returns correct prices using the same WASM.

---

### Task 8.5: Text Allocation in WASM

**Add ability to allocate Text objects from JS** (needed for future enhancements):

```typescript
// Already in runtime.ts plan from Phase 8 original
allocText(str: string): Ptr32
```

**Exit criterion:** `runtime.allocText()` works.

---

### Task 8.6: Build Pipeline

**Create build scripts:**

```json
{
  "name": "unison-wasm-demo",
  "scripts": {
    "compile": "stack exec unison-wasm-poc -- compile pricing pricing.u",
    "build:wasm": "npm run compile && wat2wasm dist/pricing.wat -o dist/pricing.wasm",
    "build:ts": "tsc",
    "build": "npm run build:wasm && npm run build:ts",
    "serve": "npx serve . -l 3000",
    "server": "ts-node server.ts",
    "dev": "npm run build && npm run serve"
  }
}
```

**Exit criterion:** `npm run dev` builds and serves the demo.

---

### Task 8.7: Memory Inspector Integration

**Add browser dev tools support:**

```typescript
runtime.exposeToDevTools('unisonRuntime');

// In browser console:
unisonRuntime.dumpHeap()
unisonRuntime.inspectValue(0x4000)
```

**Exit criterion:** Dev tools work in browser console.

---

### Task 8.8: Documentation

**Create demo documentation:**

- `demo/README.md` — How to run the demo
- Update `plans/WASM.md` Phase 8 status
- Update `AGENTS.md` with Phase 8 completion

**Exit criterion:** Documentation is complete.

---

## Exit Criteria (Concrete)

### Must Pass

1. **Instant Price Calculation**
   ```javascript
   runtime.callBigInt('calculatePrice', 5n);  // Returns 4500n ($45.00)
   runtime.callBigInt('calculatePrice', 3n);  // Returns 3000n ($30.00, no discount)
   ```

2. **Server Verification Matches**
   - Click "Verify with Server"
   - Server returns **same price** as browser
   - UI shows "✅ Server confirms"

3. **Drift Mode Demonstrates the Problem**
   - Toggle drift mode ON
   - Click "Verify with Server"
   - UI shows "⚠️ Price mismatch!" with different values

4. **Code Display Shows Shared Logic**
   - User can see the actual Unison function
   - Same function highlighted as running in both places

5. **Dev Tools Work**
   ```javascript
   unisonRuntime.dumpHeap()  // Shows heap state
   ```

### The "Aha!" Test

A non-technical person should be able to:
1. Adjust the slider → see instant price updates
2. Click verify → see "They match!"
3. Toggle drift mode → see "They don't match!"
4. Understand: "Oh, shared code = no bugs"

---

## Success Metrics

When Phase 8 is complete:

1. ✅ User can clone repo and run `npm run dev` to see demo
2. ✅ Price updates instantly as slider moves (WASM)
3. ✅ Server verification confirms same price (shared code)
4. ✅ Drift mode shows what goes wrong with duplicated code
5. ✅ Browser dev tools can inspect WASM state
6. ✅ Non-technical users understand the value proposition

---

## Implementation Order

```
Week 1: Core Demo
├── Task 8.1: Demo project structure
├── Task 8.2: Pricing logic (shared Unison)
└── Task 8.3: Demo TypeScript

Week 2: Server & Polish
├── Task 8.4: Server implementation
├── Task 8.5: Text allocation
└── Task 8.6: Build pipeline

Week 3: Finish
├── Task 8.7: Memory inspector
└── Task 8.8: Documentation
```

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| WASM loading slow | Medium | Add loading indicator, preload |
| Server setup complex | Medium | Start with simulated server, add real one later |
| Demo not compelling | High | Focus on drift mode — make the problem visible |
| Browser compatibility | Low | Test in Chrome, Firefox, Safari |

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| Phase 7 (Async) | ✅ Complete | For real server fetch |
| Phase 6 (Foreign Calls) | ✅ Complete | JS interop |
| UnisonRuntime class | ✅ Complete | Core runtime |
| wat2wasm | ✅ Available | WASM compilation |

---

## Tagline

> **"Change the pricing formula in ONE place. Browser and server update together. No drift. No bugs. No angry customers."**
