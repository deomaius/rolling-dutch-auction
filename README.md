# Rolling Dutch Auction

_This implementation has been audited at commit hash [cb27022597db95c4fd734356491bc0304e1e0721](https://github.com/deomaius/rolling-dutch-auction/tree/cb27022597db95c4fd734356491bc0304e1e0721) by the independent security reseracher [@pashovkrum](https://twitter.com/pashovkrum), you can [view the audit report here](./AUDIT.md)._

> **This is experimental software and should be used at your own discretion, the author nor auditor is not liable for any losses experienced under usage of this software**.

![image](https://i.imgur.com/uo1YECe.png)

Dutch auctions in their "vanilla" form can be a useful mechanism to raise capital for an asset with no definitive market value, although is subject to exponential volatility. Arguably alone, it is a mechanism of incredible risk as a participant - while auction operators can mitigate financial risk and maximise profits by pricing the auction at inflated values at the expense of participants. Dutch auctions are only feasible when there is a clear demand for the auctioned asset otherwise the disparity between order prices will be significant. The same argument carries weight when auctioning assets with low liquidity.

The Rolling Dutch auction is a Dutch auction derivative with composite decay, meaning, the price decay of an auction is reset to compliment a slower rate of decay proportional to bid activity. This occurs whenever an auction "window" or "tranche" is initialised, which is when a participant submits a bid; **which must be equal or greater than the current scalar price**. 

Windows essentially "freeze" the auction at the point of initiation and are configured to a prefixed duration on auction creation. When a window is active, other participants can counter bid; **which must be and greater in price and greater or equal in volume** with reasoning to mitigate spam bidding. Whenever there is a counter bid, the window's duration is reset - assigning a perpetual state to the auction. All bids are final unless void by a countering bid. 



