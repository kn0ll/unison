/**
 * Unison WASM Demo Server
 *
 * This Node.js server uses the SAME WASM module as the browser.
 * Both environments execute identical Unison code, eliminating drift.
 *
 * Usage:
 *   npm run server
 */

import express from 'express';
import { readFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = parseInt(process.env.PORT || '3001');

// WASM module interface
interface WasmExports {
  calculatePrice: (qty: bigint) => bigint;
  calculateDiscount: (qty: bigint) => bigint;
  calculateSubtotal: (qty: bigint) => bigint;
  calculatePriceWithLog: (qty: bigint) => bigint;
}

let wasmExports: WasmExports | null = null;

/**
 * Load the WASM module
 */
async function loadWasm(): Promise<void> {
  // __dirname is 'dist/' after compilation, so pricing.wasm is in same dir
  const wasmPath = join(__dirname, 'pricing.wasm');

  if (!existsSync(wasmPath)) {
    console.error('❌ WASM file not found at', wasmPath);
    console.error('   Run "npm run build:wasm" first to compile the Unison code.');
    process.exit(1);
  }

  const wasmBytes = readFileSync(wasmPath);

  // Foreign function imports - these implement IO abilities in JS
  // Same functions work in browser (console.log) and server (Node.js console.log)
  const imports = {
    unison: {
      // IO.printLine - prints a Text value (pointer to string in memory)
      'IO.printLine': (ptr: bigint) => {
        console.log('[Unison IO.printLine]', ptr);
      },
      // IO.printNat - prints a Nat value directly
      'IO.printNat': (value: bigint) => {
        const cents = Number(value);
        const dollars = Math.floor(cents / 100);
        const remainder = cents % 100;
        const formatted = `$${dollars}.${remainder.toString().padStart(2, '0')}`;
        console.log(`[Unison] Price calculated: ${formatted} (${cents} cents)`);
      }
    }
  };

  const module = await WebAssembly.instantiate(wasmBytes, imports);
  wasmExports = module.instance.exports as unknown as WasmExports;
  console.log('✅ WASM module loaded from', wasmPath);
  console.log('   Foreign functions (IO abilities) provided by Node.js');
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

  if (!wasmExports) {
    res.status(500).json({ error: 'WASM not loaded' });
    return;
  }

  // Use calculatePriceWithLog to demonstrate foreign calls (IO.printNat)
  // This will log to the server console - same as browser console.log!
  const price = Number(wasmExports.calculatePriceWithLog(BigInt(qty)));
  const discount = Number(wasmExports.calculateDiscount(BigInt(qty)));
  const subtotal = Number(wasmExports.calculateSubtotal(BigInt(qty)));

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
    note: 'Computed by the SAME Unison code as the browser! Check server logs for IO.printNat output.'
  });
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
    wasmLoaded: wasmExports !== null,
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
    console.log(`   GET /api/price?qty=5       → Uses WASM (same as browser)`);
    console.log(`   GET /api/price-drift?qty=5 → Uses JS (simulates drift)`);
    console.log(`   GET /api/health            → Health check`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  });
}

main().catch(console.error);
