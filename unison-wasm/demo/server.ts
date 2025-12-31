/**
 * Unison WASM Demo Server
 *
 * This Node.js server uses the SAME WASM module as the browser.
 * Both environments execute identical Unison code, eliminating drift.
 *
 * Uses UnisonRuntime from @unison/wasm-runtime for:
 * - Proper FFI handling (Debug.trace, etc.)
 * - Async foreign function support (IO.delay, etc.)
 * - Memory management
 *
 * Usage:
 *   npm run server
 */

import express from 'express';
import { existsSync } from 'fs';
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { UnisonRuntime } from '@unison/wasm-runtime';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = parseInt(process.env.PORT || '3001');

let runtime: UnisonRuntime | null = null;

/**
 * Load the WASM module using UnisonRuntime
 */
async function loadWasm(): Promise<void> {
  // __dirname is 'dist/' after compilation, so pricing.wasm is in same dir
  const wasmPath = join(__dirname, 'pricing.wasm');

  if (!existsSync(wasmPath)) {
    console.error('❌ WASM file not found at', wasmPath);
    console.error('   Run "npm run build:wasm" first to compile the Unison code.');
    process.exit(1);
  }

  const wasmBytes = await readFile(wasmPath);

  // Create UnisonRuntime instance
  runtime = new UnisonRuntime();

  // Register sync FFI handlers for Debug.trace/watch
  // These override the defaults to use console.log directly
  runtime.registerForeign('Debug_trace', (rt, textPtr: bigint, _valPtr: bigint): bigint => {
    const text = rt.getText(Number(textPtr));
    console.log(`[trace] ${text}`);
    return 0n; // Unit
  });

  runtime.registerForeign('Debug_watch', (rt, textPtr: bigint): bigint => {
    const text = rt.getText(Number(textPtr));
    console.log(`[watch] ${text}`);
    return textPtr;
  });

  // IO.delay.impl.v3 - ASYNC handler that actually delays
  runtime.registerAsyncForeign('IO.delay.impl.v3', async (_rt, microseconds: bigint): Promise<bigint> => {
    const ms = Number(microseconds) / 1000;
    console.log(`[IO.delay] waiting ${ms}ms...`);
    await new Promise(resolve => setTimeout(resolve, ms));
    console.log(`[IO.delay] done`);
    return 0n; // Unit (Either Right ())
  });

  // Load the WASM module
  await runtime.loadWasm(wasmBytes);

  console.log('✅ WASM module loaded from', wasmPath);
}


/**
 * Format cents as dollars
 */
function formatCents(cents: number): string {
  const dollars = Math.floor(cents / 100);
  const remainder = cents % 100;
  return `$${dollars}.${remainder.toString().padStart(2, '0')}`;
}

// Serve static files from demo directory (parent of dist/)
const demoDir = join(__dirname, '..');
app.use(express.static(demoDir));
// Also serve dist files at /dist
app.use('/dist', express.static(__dirname));

// API endpoint for price calculation (using WASM)
app.get('/api/price', (req, res) => {
  const qty = parseInt(req.query.qty as string) || 1;

  if (!runtime) {
    res.status(500).json({ error: 'WASM not loaded' });
    return;
  }

  // Call all pricing functions from WASM - compiled from Unison
  const subtotal = Number(runtime.call('calculateSubtotal', BigInt(qty)));
  const discount = Number(runtime.call('calculateDiscount', BigInt(qty)));
  // Use calculatePriceWithLog to demonstrate sync FFI (Debug.trace)
  const price = Number(runtime.call('calculatePriceWithLog', BigInt(qty)));

  res.json({
    quantity: qty,
    subtotal,
    discount,
    price,
    formatted: {
      subtotal: formatCents(subtotal),
      discount: formatCents(discount),
      price: formatCents(price),
    },
    source: 'unison-wasm',
    note: 'Computed by the SAME Unison code as the browser! Check server logs for Debug.trace output.'
  });
});

// API endpoint for ASYNC price calculation (demonstrates IO.delay)
app.get('/api/price-async', async (req, res) => {
  const qty = parseInt(req.query.qty as string) || 1;
  const delayMs = parseInt(req.query.delay as string) || 500;

  if (!runtime) {
    res.status(500).json({ error: 'WASM not loaded' });
    return;
  }

  try {
    const delayMicros = BigInt(delayMs * 1000);  // ms → microseconds
    console.log(`[API] Starting async price calculation with ${delayMs}ms delay...`);

    // Use runtime.run() for async - handles yield/resume
    const price = await runtime.run('calculatePriceWithDelay', delayMicros, BigInt(qty));

    console.log(`[API] Async calculation complete, price: ${price}`);

    res.json({
      quantity: qty,
      delay: delayMs,
      price: Number(price),
      formatted: {
        price: formatCents(Number(price)),
      },
      source: 'unison-wasm-async',
      note: `Used IO.delay (${delayMs}ms) with real async yield/resume!`
    });
  } catch (error) {
    console.error('[API] Async error:', error);
    res.status(500).json({ error: String(error) });
  }
});

// "Drift" endpoint - simulates what happens with duplicated code
// Uses 15% discount instead of 10%
app.get('/api/price-drift', (req, res) => {
  const qty = parseInt(req.query.qty as string) || 1;

  // Deliberately DIFFERENT logic (15% discount instead of 10%)
  const unitPrice = 1000;
  const subtotal = qty * unitPrice;
  const discount = qty >= 5 ? Math.floor(subtotal * 0.15) : 0;  // 15%!
  const price = subtotal - discount;

  res.json({
    quantity: qty,
    subtotal,
    discount,
    price,
    formatted: {
      subtotal: formatCents(subtotal),
      discount: formatCents(discount),
      price: formatCents(price),
    },
    source: 'javascript-drift',
    note: '⚠️ This uses DIFFERENT code (15% discount) to simulate drift!'
  });
});

// Health check
app.get('/api/health', (_, res) => {
  res.json({
    status: 'ok',
    wasmLoaded: runtime !== null,
    timestamp: new Date().toISOString()
  });
});

// Start server
async function main() {
  await loadWasm();

  app.listen(PORT, () => {
    console.log('');
    console.log('🚀 Unison WASM Demo Server');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log(`   http://localhost:${PORT}`);
    console.log('');
    console.log('   Using the SAME WASM module as the browser!');
    console.log('');
    console.log('   API Endpoints:');
    console.log(`   GET /api/price?qty=5             → Sync WASM (Debug.trace)`);
    console.log(`   GET /api/price-async?qty=5       → Async WASM (IO.delay)`);
    console.log(`   GET /api/price-drift?qty=5       → JS (simulates drift)`);
    console.log(`   GET /api/health                  → Health check`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  });
}

main().catch(console.error);
