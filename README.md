# Rolling Dutch Auction

> This implementation has been audited at commit hash [cb27022597db95c4fd734356491bc0304e1e0721](https://github.com/deomaius/rolling-dutch-auction/tree/cb27022597db95c4fd734356491bc0304e1e0721) by the independent security reseracher [@pashovkrum](https://twitter.com/pashovkrum), you can [view the audit report here](./AUDIT.md). _This is experimental software and should be used at your own discretion, the author nor auditor is not liable for any losses expierenced under usage of this software_.

Dutch auctions in their "vanilla" form can be a useful mechansim to raise capital for an asset with no definitive market value, although are subject to expontential volatility. Arguably alone, it is a mechanisim of incredible risk as a participant, while on the other hand auction operators can mitigate finanncial risk and maximise profits by pricing the auction at inflated values at the expense of participants. Dutch auction are only feasible when there is a clear demand for the auctioned asset otherwise the disparity between order prices will be significant. This argument also resonates with assets with low liquidity.

![image](https://i.imgur.com/uo1YECe.png)

The Rolling Dutch auction is a Dutch auction derivative with composite decay, meaning, the price decay of an auction is reset to compliment a more normalised depreciation proportional to bid activity. This encurs whenever an auction "window" or "tranche" is initialised, which is whenever a pariticipant submits a bid; **which must be equal or greater than the current scalar price**. 

Windows essentially "freeze" the auction at the point of initiation and are configured to a prefixed duration on auction creation, during the active state of a window other participants can counter bid; **which must be greater or equal in volume and price** with reasoning to migitate spam bidding. Whenever there is a counter bid, the window's duration is reset - assigning a perputual attribute to the auction's lifecycle. All bids are final unless void by a counter bid. 



