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
  const wasmPath = join(__dirname, 'pricing.wasm');

  if (!existsSync(wasmPath)) {
    console.error('❌ WASM file not found at', wasmPath);
    console.error('   Run "npm run build:wasm" first to compile the Unison code.');
    process.exit(1);
  }

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

  // Load from file path (Node.js convenience method)
  await runtime.loadWasmFile(wasmPath);
  console.log('✅ WASM module loaded from', wasmPath);
}

// Serve static files
const demoDir = join(__dirname, '..');
app.use(express.static(demoDir));
app.use('/dist', express.static(__dirname));

// Price endpoint - returns raw WASM result
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
    const [subtotal, discount, total] = await runtime.run('calculatePrice', delayMicros, BigInt(qty));

    res.json({
      subtotal: Number(subtotal),
      discount: Number(discount),
      total: Number(total),
    });
  } catch (error) {
    console.error('[API] Error:', error);
    res.status(500).json({ error: String(error) });
  }
});

// Start server
async function main() {
  await loadWasm();

  app.listen(PORT, () => {
    console.log('');
    console.log(`🚀 Unison WASM Demo Server: http://localhost:${PORT}`);
    console.log('');
    console.log('   API:');
    console.log(`   GET /api/price?qty=5&delay=1000`);
  });
}

main().catch(console.error);
