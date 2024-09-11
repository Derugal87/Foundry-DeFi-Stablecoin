// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions


1. Relative stability: anchored or pegged -> 1.00$
    1. Chainlink price feed;
    2. Set a fucntion to exchange  ETH & BTC -> $$$
2. Stability mechanism (minting): Algorithmic
    1. People can only mint the stablecoin with enough collateral (coded)
3. Collateral: Expgenous (crypto):
    1. wETH
    2. wBTC

- calculate health factor function
- set health factor if debt is 0
- added a bunch of view functions

1. What are our invariants/properties?
Understand the invariant and launch fuzz test on it
2. Write the functions that can execute them


Stateless fuzzing: Where the state of the previous run is discarded for every new run
Stateful fuzzing: Fuzzing where the final state of your previous run is the starting state of your next run

Fuzz tests = Random Data to one function
Invariant tests = Random Data & Random Function Calls to many functions

Examples:
Invariants - new tokens minted < inflations rate; or Only possible to have 1 winner in a lottery; or Only withdraw what they deposit



## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
