# Rolling Dutch Auction

> Audited by [@pashovkrum]() | commit hash [cb27022597db95c4fd734356491bc0304e1e0721]() | [Report](./AUDIT.md)

A Dutch auction derivative with composite decay.

## Overview

Composite decay resets a point on the curve to it's current coordinates normalising the slope, making price decay inversely proportional to bid activity. This occurs whenever an auction "window" or "tranche" is initialised, which is when a participant submits a bid; which must be equal or greater than the current scalar price.

![image](https://i.imgur.com/uo1YECe.png)

The Rolling Dutch auction introduces composite decay, meaning the price decay of an auction is reset to compliment a slower rate of decay proportional to bid activity. This occurs whenever an auction "window" or "tranche" is initialised, which is when a participant submits a bid; which must be equal or greater than the current scalar price.

## How It Works

1. **Composite Decay**:
   - Price decay resets on bids
   - Slower decay rate over time
   - Proportional to bid activity
   - Window-based pricing

2. **Bidding Windows**:
   - Activated by valid bids
   - Fixed duration per window
   - Reset on counter bids
   - Creates perpetual state

3. **Bid Requirements**:
   - Must meet/exceed scalar price
   - Must exceed previous bid price
   - Must meet/exceed previous volume

## Contributing

@TODO

## License

See [License](./LICENSE)
