# Setup Demo Codebase

This transcript creates the demo codebase with pricing functions.

``` ucm
demo/main> lib.install @unison/base

  I installed @unison/base/releases/7.10.0 into
  lib.unison_base_7_10_0

demo/main> load src/pricing.u

  Loading changes detected in src/pricing.u.

  + calculateDiscount     : Nat -> Nat
  + calculatePrice        : Nat -> Nat
  + calculatePriceWithLog : Nat -> Nat
  + calculateSubtotal     : Nat -> Nat
  + hasBulkDiscount       : Nat -> Boolean

  Run `update` to apply these changes to your codebase.

demo/main> add

  Done.
```
