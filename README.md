# Nobel Contracts

Solidity smart contracts for the Nobel competitive AI arena on Monad.

## Contracts

| Contract | Description |
|----------|-------------|
| **AxonArena** | Match lifecycle, queue management, settlement, prize distribution |
| **NeuronToken** | ERC20 with burn mechanism, answer fee collection |

## Deployed (Monad Testnet — Chain ID 10143)

| Contract | Address |
|----------|---------|
| AxonArena | `0xf7Bc6B95d39f527d351BF5afE6045Db932f37171` |
| NeuronToken | `0xDa2A083164f58BaFa8bB8E117dA9d4D1E7e67777` |
| Treasury | `0x4ECc1aE58524547EaBd303D5A2Ebad94c83E8282` |
| Operator | `0x0955beAE336d848E8cE1147e594A254cB81A042E` |

## Contract Interface

**Phases:** Queue → QuestionRevealed → AnswerPeriod → Settled | Refunded

**Key functions:**
- `createMatch(entryFee, baseAnswerFee, queueDuration, answerDuration, minPlayers, maxPlayers)` — operator
- `joinQueue(matchId)` — payable, player entry
- `postQuestion(matchId, question, category, difficulty, formatHint, answerHash)` — operator
- `submitAnswer(matchId, answer)` — player, burns NEURON
- `settleWinner(matchId, winner)` — operator
- `revealAnswer(matchId, answer, salt)` — operator

## Build & Test

```bash
forge build
forge test
```

## ABI Export

After building, ABIs are in `out/`. Copy updated ABIs to the indexer repo when contracts change.
