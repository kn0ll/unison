/**
 * Unison WASM Demo - Price Calculator
 *
 * This demo shows how the same Unison code can run in both:
 * - Browser (compiled to WASM)
 * - Server (same WASM via Node.js)
 *
 * Uses UnisonRuntime from @unison/wasm-runtime for consistent FFI handling.
 *
 * The "Drift Mode" feature demonstrates what goes wrong when
 * frontend and backend have different implementations.
 */

// UnisonRuntime is loaded separately via index.html and available globally
// This avoids bundler complexity for the demo
interface IUnisonRuntime {
  registerForeign(name: string, handler: (rt: IUnisonRuntime, ...args: bigint[]) => bigint | void): void;
  registerAsyncForeign(name: string, handler: (rt: IUnisonRuntime, ...args: bigint[]) => Promise<bigint>): void;
  loadWasm(bytes: BufferSource): Promise<void>;
  call(funcName: string, ...args: unknown[]): unknown;
  run(funcName: string, ...args: unknown[]): Promise<bigint>;
  getText(ptr: number): string;
}

declare const UnisonRuntime: new () => IUnisonRuntime;

let runtime: IUnisonRuntime | null = null;
let driftMode = false;

// DOM Elements
let qtySlider: HTMLInputElement;
let qtyDisplay: HTMLElement;
let subtotalEl: HTMLElement;
let discountEl: HTMLElement;
let totalEl: HTMLElement;
let verifyBtn: HTMLButtonElement;
let serverResult: HTMLElement;
let serverMessage: HTMLElement;
let driftToggle: HTMLElement;
let driftLabel: HTMLElement;
let driftWarning: HTMLElement;
let loadingEl: HTMLElement;
let appEl: HTMLElement;
let errorBanner: HTMLElement;
let errorMessage: HTMLElement;

/**
 * Initialize the demo
 */
async function init(): Promise<void> {
  // Get DOM elements
  qtySlider = document.getElementById('quantity') as HTMLInputElement;
  qtyDisplay = document.getElementById('qty-display')!;
  subtotalEl = document.getElementById('subtotal')!;
  discountEl = document.getElementById('discount')!;
  totalEl = document.getElementById('total')!;
  verifyBtn = document.getElementById('verify-btn') as HTMLButtonElement;
  serverResult = document.getElementById('server-result')!;
  serverMessage = document.getElementById('server-message')!;
  driftToggle = document.getElementById('drift-toggle')!;
  driftLabel = document.getElementById('drift-label')!;
  driftWarning = document.getElementById('drift-warning')!;
  loadingEl = document.getElementById('loading')!;
  appEl = document.getElementById('app')!;
  errorBanner = document.getElementById('error-banner')!;
  errorMessage = document.getElementById('error-message')!;

  // Show loading state
  loadingEl.classList.add('visible');

  try {
    // Load the WASM module
    await loadWasm();

    // Wire up event handlers
    qtySlider.addEventListener('input', updatePrice);
    verifyBtn.addEventListener('click', verifyWithServer);
    driftToggle.addEventListener('click', toggleDrift);

    // Initial calculation
    updatePrice();

    // Show the app
    loadingEl.classList.remove('visible');
    appEl.style.display = 'block';

    // Expose runtime to dev tools
    exposeToDevTools();

    console.log('✅ Unison WASM demo initialized!');
  } catch (error) {
    showError(error instanceof Error ? error.message : String(error));
  }
}

/**
 * Load the compiled WASM module using UnisonRuntime
 */
async function loadWasm(): Promise<void> {
  const response = await fetch('./dist/pricing.wasm');
  if (!response.ok) {
    throw new Error(
      `Failed to load WASM module: ${response.status} ${response.statusText}\n\n` +
      `Make sure to run 'npm run build:wasm' first to compile the Unison code.`
    );
  }
  const bytes = await response.arrayBuffer();

  // Create UnisonRuntime instance (same as server.ts)
  runtime = new UnisonRuntime();

  // Register sync FFI handlers for Debug.trace/watch
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

  // IO.delay.impl.v3 handler - sync stub for browser
  // Full async would require yield/resume
  runtime.registerForeign('IO_delay_impl_v3', (_rt, microseconds: bigint): bigint => {
        const ms = Number(microseconds) / 1000;
    console.log(`[IO.delay] ${ms}ms (sync stub)`);
    return 0n; // Unit
  });

  // Load the WASM module
  await runtime.loadWasm(bytes);

  console.log('✅ WASM module loaded');
}

/**
 * Update the price display based on current quantity
 */
function updatePrice(): void {
  if (!runtime) return;

  const qty = BigInt(qtySlider.value);

  // Call all WASM functions - compiled from Unison
  const subtotal = Number(runtime.call('calculateSubtotal', qty));
  const discount = Number(runtime.call('calculateDiscount', qty));
  const total = Number(runtime.call('calculatePriceWithDelay', qty, 0));

  // Update UI
  qtyDisplay.textContent = qtySlider.value;
  subtotalEl.textContent = formatCents(subtotal);
  discountEl.textContent = discount > 0 ? `-${formatCents(discount)}` : '$0.00';
  totalEl.textContent = formatCents(total);

  // Hide previous server result
  serverResult.style.display = 'none';
}

/**
 * Verify the calculation with the actual server
 */
async function verifyWithServer(): Promise<void> {
  if (!runtime) return;

  const qty = parseInt(qtySlider.value);
  const clientPrice = Number(runtime.call('calculatePrice', BigInt(qty)));

  verifyBtn.disabled = true;
  verifyBtn.textContent = 'Verifying...';

  try {
    // Make actual API call to server
    const endpoint = driftMode ? '/api/price-drift' : '/api/price';
    const response = await fetch(`${endpoint}?qty=${qty}`);

    if (!response.ok) {
      throw new Error(`Server error: ${response.status}`);
    }

    const data = await response.json();
    const serverPrice = data.price as number;

    // Show result
    serverResult.style.display = 'block';

    if (serverPrice === clientPrice) {
      serverResult.className = 'server-result';
      serverMessage.innerHTML = `
        ✅ <strong>Server confirms: ${formatCents(serverPrice)}</strong><br>
        <span style="color: var(--muted)">Both computed by the SAME Unison code!</span>
      `;
    } else {
      serverResult.className = 'server-result drift';
      serverMessage.innerHTML = `
        ⚠️ <strong>Price mismatch!</strong><br>
        Browser: ${formatCents(clientPrice)}<br>
        Server: ${formatCents(serverPrice)}<br>
        <span style="color: var(--warning)">This is what happens with duplicated code!</span>
      `;
    }
  } catch (error) {
    serverResult.style.display = 'block';
    serverResult.className = 'server-result error';
    serverMessage.innerHTML = `
      ❌ <strong>Server error</strong><br>
      ${error instanceof Error ? error.message : String(error)}<br>
      <span style="color: var(--muted)">Make sure the server is running: npm run server</span>
    `;
  } finally {
    verifyBtn.disabled = false;
    verifyBtn.textContent = 'Verify with Server';
  }
}

/**
 * Toggle drift mode on/off
 */
function toggleDrift(): void {
  driftMode = !driftMode;

  driftToggle.classList.toggle('on', driftMode);
  driftLabel.textContent = driftMode
    ? 'ON — Simulating duplicated code'
    : 'OFF — Using shared Unison code';
  driftWarning.style.display = driftMode ? 'block' : 'none';

  // Hide server result when toggling
  serverResult.style.display = 'none';
}

/**
 * Format cents as dollars
 */
function formatCents(cents: number): string {
  const dollars = Math.floor(cents / 100);
  const remainder = cents % 100;
  return `$${dollars}.${remainder.toString().padStart(2, '0')}`;
}

/**
 * Show an error to the user
 */
function showError(message: string): void {
  loadingEl.classList.remove('visible');
  errorBanner.classList.add('visible');
  errorMessage.textContent = message;
}

/**
 * Expose runtime to browser dev tools
 */
function exposeToDevTools(): void {
  (window as unknown as Record<string, unknown>)['unisonRuntime'] = {
    runtime,
    calculatePrice: (qty: number) => runtime ? Number(runtime.call('calculatePrice', BigInt(qty))) : 0,
    calculateDiscount: (qty: number) => runtime ? Number(runtime.call('calculateDiscount', BigInt(qty))) : 0,
    calculateSubtotal: (qty: number) => runtime ? Number(runtime.call('calculateSubtotal', BigInt(qty))) : 0,
  };
  console.log('🔧 Dev tools: window.unisonRuntime');
}

// Start the demo
document.addEventListener('DOMContentLoaded', init);
