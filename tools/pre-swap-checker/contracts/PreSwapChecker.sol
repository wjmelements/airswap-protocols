pragma solidity ^0.5.10;
pragma experimental ABIEncoderV2;

import "@airswap/types/contracts/Types.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC721/IERC721.sol";
import "openzeppelin-solidity/contracts/introspection/ERC165Checker.sol";
import "@airswap/swap/contracts/interfaces/ISwap.sol";
import "@airswap/transfers/contracts/TransferHandlerRegistry.sol";
import "@airswap/tokens/contracts/interfaces/IWETH.sol";
import "@airswap/delegate/contracts/interfaces/IDelegate.sol";

/**
  * @title PreSwapChecker: Helper contract to Swap protocol
  * @notice contains several helper methods that check whether
  * a Swap.order is well-formed and counterparty criteria is met
  */
contract PreSwapChecker {
  using ERC165Checker for address;

  bytes constant internal DOM_NAME = "SWAP";
  bytes constant internal DOM_VERSION = "2";

  bytes4 constant internal ERC721_INTERFACE_ID = 0x80ac58cd;
  bytes4 constant internal ERC20_INTERFACE_ID = 0x36372b07;

  IWETH public wethContract;

  /**
    * @notice Contract Constructor
    * @param preSwapCheckerWethContract address
    */
  constructor(
    address preSwapCheckerWethContract
  ) public {
    wethContract = IWETH(preSwapCheckerWethContract);
  }

  /**
    * @notice If order is going through delegate via provideOrder
    * ensure necessary checks are set
    * @param order Types.Order
    * @param delegate IDelegate
    * @return uint256 errorCount if any
    * @return bytes32[] memory array of error messages
    */
  function checkSwapDelegate(
    Types.Order calldata order,
    IDelegate delegate
    ) external view returns (uint256, bytes32[] memory ) {

    bytes32[] memory errors = new bytes32[](20);
    uint256 errorCount;
    address swap = order.signature.validator;
    IDelegate.Rule memory rule = delegate.rules(order.sender.token,order.signer.token);
    (uint256 swapErrorCount, bytes32[] memory swapErrors) = checkSwapSwap(order, false);

    if (swapErrorCount > 0) {
      errorCount = swapErrorCount;
      // copies over errors from checkSwapSwap to be outputted
      for (uint256 i = 0; i < swapErrorCount; i++) {
        errors[i] = swapErrors[i];
      }
    }

    // signature must be filled in order to use the Delegate
    if (order.signature.v == 0) {
      errors[errorCount] = "SIGNATURE_MUST_BE_SENT";
      errorCount++;
    }

    // check that the sender.wallet == tradewallet
    if (order.sender.wallet != delegate.tradeWallet()) {
      errors[errorCount] = "SENDER_WALLET_INVALID";
      errorCount++;
    }

    // ensure signer kind is ERC20
    if (order.signer.kind != ERC20_INTERFACE_ID) {
      errors[errorCount] = "SIGNER_KIND_MUST_BE_ERC20";
      errorCount++;
    }

    // ensure sender kind is ERC20
    if (order.sender.kind != ERC20_INTERFACE_ID) {
      errors[errorCount] = "SENDER_KIND_MUST_BE_ERC20";
      errorCount++;
    }

    // ensure that token pair is active with non-zero maxSenderAmount
    if (rule.maxSenderAmount == 0) {
      errors[errorCount] = "TOKEN_PAIR_INACTIVE";
      errorCount++;
    }

    if (order.sender.amount > rule.maxSenderAmount) {
      errors[errorCount] = "ORDER_AMOUNT_EXCEEDS_MAX";
      errorCount++;
    }

    // calls the getSenderSize quote to determine how much needs to be paid
    uint256 senderAmount = delegate.getSenderSideQuote(order.signer.amount, order.signer.token, order.sender.token);
    if (senderAmount == 0) {
      errors[errorCount] = "DELEGATE_UNABLE_TO_PRICE";
      errorCount++;
    } else if (order.sender.amount > senderAmount) {
      errors[errorCount] = "PRICE_INVALID";
      errorCount++;
    }

    // ensure that tradeWallet has approved delegate contract on swap
    if (!ISwap(swap).senderAuthorizations(order.sender.wallet, address(delegate))) {
      errors[errorCount] = "SENDER_UNAUTHORIZED";
      errorCount++;
    }

    return (errorCount, errors);
  }

  /**
    * @notice If order is going through wrapper to swap
    * @param order Types.Order
    * @param fromAddress address
    * @param wrapper address
    * @return uint256 errorCount if any
    * @return bytes32[] memory array of error messages
    */
  function checkSwapWrapper(
    Types.Order calldata order,
    address fromAddress,
    address wrapper
    ) external view returns (uint256, bytes32[] memory ) {
    address swap = order.signature.validator;
    // max size of the number of errors that could exist
    bytes32[] memory errors = new bytes32[](20);
    uint256 errorCount;

    (uint256 swapErrorCount, bytes32[] memory swapErrors) = checkSwapSwap(order, true);

    if (swapErrorCount > 0) {
      errorCount = swapErrorCount;
      // copies over errors from checkSwapSwap to be outputted
      for (uint256 i = 0; i < swapErrorCount; i++) {
        errors[i] = swapErrors[i];
      }
    }

    if (order.sender.wallet != fromAddress) {
      errors[errorCount] = "MSG_SENDER_MUST_BE_ORDER_SENDER";
      errorCount++;
    }

    // ensure that sender has approved wrapper contract on swap
    if (!ISwap(swap).senderAuthorizations(order.sender.wallet, wrapper)) {
      errors[errorCount] = "SENDER_UNAUTHORIZED";
      errorCount++;
    }

    // signature must be filled in order to use the Wrapper
    if (order.signature.v == 0) {
      errors[errorCount] = "SIGNATURE_MUST_BE_SENT";
      errorCount++;
    }

    // if sender has WETH token, ensure sufficient ETH balance
    if (order.sender.token == address(wethContract)) {
      if (address(order.sender.wallet).balance < order.sender.amount) {
        errors[errorCount] = "SENDER_INSUFFICIENT_ETH";
        errorCount++;
      }
    }

    // ensure that sender wallet if receiving weth has approved
    // the wrapper to transfer weth and deliver eth to the sender
    if (order.signer.token == address(wethContract)) {
      uint256 allowance = wethContract.allowance(order.sender.wallet, wrapper);
      if (allowance < order.signer.amount) {
        errors[errorCount] = "LOW_SENDER_ALLOWANCE_ON_WRAPPER";
        errorCount++;
      }
    }
    return (errorCount, errors);
  }

  /**
    * @notice Takes in an order and outputs any
    * errors that Swap would revert on
    * @param order Types.Order Order to settle
    * @return uint256 errorCount if any
    * @return bytes32[] memory array of error messages
    */
  function checkSwapSwap(
    Types.Order memory order,
    bool usingWrapper
  ) public view returns (uint256, bytes32[] memory) {
    address swap = order.signature.validator;
    bytes32 domainSeparator = Types.hashDomain(DOM_NAME, DOM_VERSION, swap);

    // max size of the number of errors that could exist
    bytes32[] memory errors = new bytes32[](14);
    uint256 errorCount;

    // Check self transfer
    if (order.signer.wallet == order.sender.wallet) {
      errors[errorCount] = "SELF_TRANSFER_INVALID";
      errorCount++;
    }

    // Check expiry
    if (order.expiry < block.timestamp) {
      errors[errorCount] = "ORDER_EXPIRED";
      errorCount++;
    }

    if (ISwap(swap).signerNonceStatus(order.signer.wallet, order.nonce) != 0x00) {
      errors[errorCount] = "ORDER_TAKEN_OR_CANCELLED";
      errorCount++;
    }

    if (order.nonce < ISwap(swap).signerMinimumNonce(order.signer.wallet)) {
      errors[errorCount] = "NONCE_TOO_LOW";
      errorCount++;
    }

    // check if ERC721 or ERC20 only amount or id set for sender
    if (order.sender.kind == ERC20_INTERFACE_ID && order.sender.id != 0) {
      errors[errorCount] = "SENDER_INVALID_ID";
      errorCount++;
    } else if (order.sender.kind == ERC721_INTERFACE_ID && order.sender.amount != 0) {
      errors[errorCount] = "SENDER_INVALID_AMOUNT";
      errorCount++;
    }

    // check if ERC721 or ERC20 only amount or id set for signer
    if (order.signer.kind == ERC20_INTERFACE_ID && order.signer.id != 0) {
      errors[errorCount] = "SIGNER_INVALID_ID";
      errorCount++;
    } else if (order.signer.kind == ERC721_INTERFACE_ID && order.signer.amount != 0) {
      errors[errorCount] = "SIGNER_INVALID_AMOUNT";
      errorCount++;
    }

    // Check valid token registry handler for sender
    if (hasValidKind(order.sender.kind, swap)) {
      // Check the order sender
      if (order.sender.wallet != address(0)) {
        // The sender was specified
        // Check if sender kind interface can correctly check balance
        if (order.sender.kind == ERC721_INTERFACE_ID && !hasValidERC71Interface(order.sender.token)) {
          errors[errorCount] = "SENDER_INVALID_ERC721";
          errorCount++;
        } else {
          // Check the order sender token balance
          if ((usingWrapper && order.sender.token != address(wethContract)) || !usingWrapper) {
            //do the balance check
            if (!hasBalance(order.sender)) {
              errors[errorCount] = "SENDER_BALANCE";
              errorCount++;
            }
          }

          // Check their approval
          if (!isApproved(order.sender, swap)) {
            errors[errorCount] = "SENDER_ALLOWANCE";
            errorCount++;
          }
        }
      }
    } else {
      errors[errorCount] = "SENDER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

     // Check valid token registry handler for signer
    if (hasValidKind(order.signer.kind, swap)) {
      // Check if sender kind interface can correctly check balance
      if (order.signer.kind == ERC721_INTERFACE_ID && !hasValidERC71Interface(order.signer.token)) {
        errors[errorCount] = "SIGNER_INVALID_ERC721";
        errorCount++;
      } else {
        // Check the order signer token balance
        if (!hasBalance(order.signer)) {
          errors[errorCount] = "SIGNER_BALANCE";
          errorCount++;
        }

        // Check their approval
        if (!isApproved(order.signer, swap)) {
          errors[errorCount] = "SIGNER_ALLOWANCE";
          errorCount++;
        }
      }
    } else {
      errors[errorCount] = "SIGNER_TOKEN_KIND_UNKNOWN";
      errorCount++;
    }

    if (!isValid(order, domainSeparator)) {
      errors[errorCount] = "SIGNATURE_INVALID";
      errorCount++;
    }

    if (order.signature.signatory != order.signer.wallet) {
      if(!ISwap(swap).signerAuthorizations(order.signer.wallet, order.signature.signatory)) {
        errors[errorCount] = "SIGNER_UNAUTHORIZED";
        errorCount++;
      }
    }
    return (errorCount, errors);
  }

  /**
    * @notice Checks if kind is found in
    * Swap's Token Registry
    * @param kind bytes4 token type to search for
    * @param swap address Swap contract address
    * @return bool whether kind inserted is valid
    */
  function hasValidKind(
    bytes4 kind,
    address swap
  ) internal view returns (bool) {
    TransferHandlerRegistry tokenRegistry = ISwap(swap).registry();
    return (address(tokenRegistry.transferHandlers(kind)) != address(0));
  }

  /**
    * @notice Checks token has valid ERC721 interface
    * @param tokenAddress address potential ERC721 token address
    * @return bool whether address has valid interface
    */
  function hasValidERC71Interface(
    address tokenAddress
  ) internal view returns (bool) {
    return (tokenAddress._supportsInterface(ERC721_INTERFACE_ID));
  }

  /**
    * @notice Check a party has enough balance to swap
    * for ERC721 and ERC20 tokens
    * @param party Types.Party party to check balance for
    * @return bool whether party has enough balance
    */
  function hasBalance(
    Types.Party memory party
  ) internal view returns (bool) {
    if (party.kind == ERC721_INTERFACE_ID) {
      address owner = IERC721(party.token).ownerOf(party.id);
      return (owner == party.wallet);
    }

    uint256 balance = IERC20(party.token).balanceOf(party.wallet);
    return (balance >= party.amount);
  }

  /**
    * @notice Check a party has enough allowance to swap
    * for ERC721 and ERC20 tokens
    * @param party Types.Party party to check allowance for
    * @param swap address Swap address
    * @return bool whether party has sufficient allowance
    */
  function isApproved(
    Types.Party memory party,
    address swap
  ) internal view returns (bool) {
    if (party.kind == ERC721_INTERFACE_ID) {
      address approved = IERC721(party.token).getApproved(party.id);
      return (swap == approved);
    }
    uint256 allowance = IERC20(party.token).allowance(party.wallet, swap);
    return (allowance >= party.amount);
  }

  /**
    * @notice Check order signature is valid
    * @param order Types.Order Order to validate
    * @param domainSeparator bytes32 Domain identifier used in signatures (EIP-712)
    * @return bool True if order has a valid signature
    */
  function isValid(
    Types.Order memory order,
    bytes32 domainSeparator
  ) internal pure returns (bool) {
    if (order.signature.v == 0) {
      return true;
    }
    if (order.signature.version == byte(0x01)) {
      return order.signature.signatory == ecrecover(
        Types.hashOrder(
          order,
          domainSeparator
        ),
        order.signature.v,
        order.signature.r,
        order.signature.s
      );
    }
    if (order.signature.version == byte(0x45)) {
      return order.signature.signatory == ecrecover(
        keccak256(
          abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            Types.hashOrder(order, domainSeparator)
          )
        ),
        order.signature.v,
        order.signature.r,
        order.signature.s
      );
    }
    return false;
  }

}