/**
 * Unison WASM Demo Server
 *
 * This Node.js server uses the SAME WASM module as the browser.
 * Both environments execute identical Unison code, eliminating drift.
 *
 * Usage:
 *   npm run server
 */

/// <reference path="./dist/pricing.d.ts" />

import express from 'express';
import { existsSync } from 'fs';
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { UnisonRuntime, FunctionSignatures } from '@unison/wasm-runtime';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = parseInt(process.env.PORT || '3001');

let runtime: UnisonRuntime | null = null;

/**
 * Call a Unison function and parse the DataG result as a tuple.
 */
async function runTyped<K extends keyof FunctionSignatures>(
  funcName: K,
  ...args: FunctionSignatures[K] extends (...a: infer A) => any ? A : never[]
): Promise<FunctionSignatures[K] extends (...a: any[]) => infer R ? R : never> {
  if (!runtime) throw new Error('Runtime not loaded');
  const ptr = await (runtime as any).run(funcName, ...args);
  return runtime.readDataGFields(Number(ptr)) as any;
}

/**
 * Load the WASM module using UnisonRuntime
 */
async function loadWasm(): Promise<void> {
  const wasmPath = join(__dirname, 'pricing.wasm');

  if (!existsSync(wasmPath)) {
    console.error('❌ WASM file not found at', wasmPath);
    console.error('   Run "npm run build:wasm" first to compile the Unison code.');
    process.exit(1);
  }

  const wasmBytes = await readFile(wasmPath);

  runtime = new UnisonRuntime();

  // Debug.trace - log to console
  runtime.registerForeign('Debug_trace', (rt, textPtr: bigint, _valPtr: bigint): bigint => {
    const text = rt.getText(Number(textPtr));
    console.log(`[trace] ${text}`);
    return 0n;
  });

  // Debug.watch - log and return value
  runtime.registerForeign('Debug_watch', (rt, textPtr: bigint): bigint => {
    const text = rt.getText(Number(textPtr));
    console.log(`[watch] ${text}`);
    return textPtr;
  });

  // IO.delay.impl.v3 - async delay with real setTimeout
  runtime.registerAsyncForeign('IO.delay.impl.v3', async (_rt, microseconds: bigint): Promise<bigint> => {
    const ms = Number(microseconds) / 1000;
    console.log(`[IO.delay] waiting ${ms}ms...`);
    await new Promise(resolve => setTimeout(resolve, ms));
    console.log(`[IO.delay] done`);
    return 0n;
  });

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

// Serve static files
const demoDir = join(__dirname, '..');
app.use(express.static(demoDir));
app.use('/dist', express.static(__dirname));

// Unified price endpoint
// GET /api/price?qty=5&delay=500
app.get('/api/price', async (req, res) => {
  const qty = parseInt(req.query.qty as string) || 1;
  const delayMs = parseInt(req.query.delay as string) || 0;

  if (!runtime) {
    res.status(500).json({ error: 'WASM not loaded' });
    return;
  }

  try {
    const delayMicros = BigInt(delayMs * 1000);
    const startTime = Date.now();

    // Call calculatePrice - fully typed via runTyped
    const [subtotal, discount, total] = await runTyped('calculatePrice', delayMicros, BigInt(qty));
    const elapsed = Date.now() - startTime;

    res.json({
      quantity: qty,
      delay: delayMs,
      elapsed,
      subtotal: Number(subtotal),
      discount: Number(discount),
      total: Number(total),
      formatted: {
        subtotal: formatCents(Number(subtotal)),
        discount: formatCents(Number(discount)),
        total: formatCents(Number(total)),
      },
      source: 'unison-wasm'
    });
  } catch (error) {
    console.error('[API] Error:', error);
    res.status(500).json({ error: String(error) });
  }
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
    console.log('   API:');
    console.log(`   GET /api/price?qty=5&delay=1000`);
    console.log(`   GET /api/health`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  });
}

main().catch(console.error);
