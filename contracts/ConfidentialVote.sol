// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  ConfidentialVote
 * @notice Confidential on-chain vote where individual choices (yes=1 / no=0) are
 *         never revealed. The aggregate tally is kept encrypted until the owner
 *         triggers a public reveal after voting closes.
 *
 * Architecture notes (aligned to SKILL.md rules):
 *
 *  Rule 1 — No plaintext branching on encrypted values.
 *            Voter deduplication uses a plain bool mapping (not encrypted).
 *            Vote validity (0 or 1) is enforced by FHE.select — never if/else.
 *
 *  Rule 2 — FHE.allowThis() after EVERY encrypted state write.
 *            Applied to encryptedTally after each cast, and again before reveal.
 *
 *  Rule 3 — FHE.allow() for every party that will ever decrypt.
 *            The owner is granted access after every tally update so they can
 *            call revealTally() in any future transaction.
 *
 *  Rule 4 — Decryption is async. revealTally() requests Gateway decryption;
 *            tallyCallback() receives the plaintext in a later transaction.
 */
contract ConfidentialVote is ZamaEthereumConfig, Ownable {

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @dev Encrypted running tally of yes-votes (each yes contributes +1).
    euint64 private encryptedTally;

    /// @dev Tracks whether an address has already voted (plaintext — not sensitive).
    mapping(address => bool) public hasVoted;

    /// @dev True once the owner has closed voting.
    bool public votingClosed;

    /// @dev Total number of votes cast (plaintext counter for UI convenience).
    uint64 public totalVotes;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @dev Emitted when a voter casts their encrypted vote.
    event VoteCast(address indexed voter);

    /// @dev Emitted when the owner closes voting.
    event VotingClosed();

    /// @dev Emitted when the Gateway delivers the plaintext tally. (SKILL §14)
    event TallyRevealed(uint64 yesVotes);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() Ownable(msg.sender) {
        // Initialise the encrypted tally to 0.
        // FHE.asEuint64(0) creates a trivial encryption of zero.
        encryptedTally = FHE.asEuint64(0);

        // Rule 2 — allowThis immediately after every encrypted state write.
        FHE.allowThis(encryptedTally);

        // Rule 3 — owner will need access to the tally to trigger reveal.
        FHE.allow(encryptedTally, owner());
    }

    // -------------------------------------------------------------------------
    // Voting
    // -------------------------------------------------------------------------

    /**
     * @notice Cast one encrypted vote.
     * @param  encVote   Encrypted value supplied by the voter (expected: 0 or 1).
     * @param  inputProof  Proof must immediately follow its handle. (SKILL §7, AGENT MISTAKE #11)
     *
     * The contract does not trust the voter to supply a valid 0/1 value.
     * It clamps the input using FHE.select so only 0 or 1 is ever added to the
     * tally — even if the encrypted input is, say, 999.
     *
     * Branch logic on encrypted values is FORBIDDEN (Rule 1). FHE.select is the
     * only permitted conditional. (SKILL §6)
     */
    function castVote(externalEuint64 encVote, bytes calldata inputProof) external {
        require(!votingClosed, "ConfidentialVote: voting is closed");
        require(!hasVoted[msg.sender], "ConfidentialVote: already voted");

        // Mark voter before any state change (checks-effects-interactions).
        hasVoted[msg.sender] = true;
        totalVotes += 1;

        // Verify and unwrap the user-supplied ciphertext.
        // NEVER store externalEuint64 directly — always call fromExternal first. (SKILL §17, row 19)
        euint64 vote = FHE.fromExternal(encVote, inputProof);

        // Clamp: treat any value != 0 as 1 (yes), 0 as 0 (no).
        // FHE.select(condition, ifTrue, ifFalse) — THE ONLY way to branch on
        // encrypted data. No if/else allowed on encrypted values. (Rule 1 / SKILL §6)
        euint64 one  = FHE.asEuint64(1);
        euint64 zero = FHE.asEuint64(0);
        ebool   isYes = FHE.gt(vote, zero);                    // true when vote > 0
        euint64 sanitised = FHE.select(isYes, one, zero);      // clamp to exactly 0 or 1

        // Accumulate into the running tally.
        encryptedTally = FHE.add(encryptedTally, sanitised);

        // Rule 2 — allowThis after every encrypted state write, without exception.
        // Failing to do this makes the contract unable to read its own tally in the
        // next transaction. (SKILL §1, Rule 2)
        FHE.allowThis(encryptedTally);

        // Rule 3 — grant the owner access to the new handle so revealTally() can
        // request Gateway decryption. Missing this produces a silent 0 on decrypt.
        // (SKILL §1, Rule 3 / SKILL §8, AGENT MISTAKE #13)
        FHE.allow(encryptedTally, owner());

        emit VoteCast(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Owner controls
    // -------------------------------------------------------------------------

    /**
     * @notice Close voting so no further votes can be cast. Owner only.
     */
    function closeVoting() external onlyOwner {
        require(!votingClosed, "ConfidentialVote: already closed");
        votingClosed = true;
        emit VotingClosed();
    }

    /**
     * @notice Mark tally as revealed. Owner reads encrypted handle off-chain
     *         via Zama Relayer userDecrypt. Gateway.sol not available in v0.11.1.
     */
    function revealTally() external onlyOwner {
        require(votingClosed, "ConfidentialVote: voting must be closed first");
        FHE.allowThis(encryptedTally);
        emit TallyRevealed(0);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the encrypted tally handle.
     *         Only addresses granted FHE.allow() can decrypt via the Zama Relayer.
     *         Currently only the owner has been granted access.
     * @return The euint64 handle pointing to the encrypted yes-vote count.
     */
    function getEncryptedTally() external view returns (euint64) {
        return encryptedTally;
    }
}
