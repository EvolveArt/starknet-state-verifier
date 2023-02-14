// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 <0.9.0;
import "./EllipticCurve.sol";
import "./PedersenHash.sol";
import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

enum NodeType {
    BINARY,
    EDGE
}

struct ContractData {
    uint256 contractStateRoot;
    uint256 contractAddress;
    uint256 storageVarAddress;
    uint256 classHash;
    uint256 hashVersion;
    uint256 nonce;
}

struct BinaryProof {
    uint256 leftHash;
    uint256 rightHash;
}

struct EdgeProof {
    uint256 childHash;
    uint256 path;
    uint256 length;
}

struct StarknetProof {
    NodeType nodeType;
    BinaryProof binaryProof;
    EdgeProof edgeProof;
}

// includes contract proof and state/storage proof for a partciular starknet block
struct StarknetCompositeStateProof {
    int256 blockNumber;
    ContractData contractData;
    StarknetProof[] contractProofArray;
    StarknetProof[] storageProofArray;
}

interface IStarknetResolverService {
    function addr(bytes32 node)
        external
        view
        returns (StarknetCompositeStateProof memory proof);
}

// Starknet Core Contract Minimal Interface
// Defining the parts of the core contract interface that we need. i.e. stateRoot and stateBlockNumber
interface StarknetCoreContract {
    /**
        Returns the current state root.
        */
    function stateRoot() external view returns (uint256);

    /**
        Returns the current block number.
        */
    function stateBlockNumber() external view returns (int256);
}

// Starknet Proof Verifier. This contract verifies a Starknet proof for a contract and a storage address/value
contract StarknetVerifier is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ERC165
{
    uint256 private constant BIG_PRIME =
        3618502788666131213697322783095070105623107215331596699973092056135872020481;
    string[] public gateways;
    uint256 public l2resolver;
    PedersenHash public pedersen;
    StarknetCoreContract public starknetCoreContract;
    bytes4 private constant ADDR_INTERFACE_ID = 0x3b3b57de;
    bytes4 private constant ADDRESS_INTERFACE_ID = 0xf1cb7e06;

    error OffchainLookup(
        address sender,
        string[] urls,
        bytes callData,
        bytes4 callbackFunction,
        bytes extraData
    );

    uint256 constant MASK_250 = (2**250) - 1; // to simulate sn_keccak
    uint256 constant storageVarName =
        0x29539a1d23af1810c48a07fe7fc66a3b34fbc8b37e9b3cdb97bb88ceab7e4bf; // sn_keccak of 'resolver' in https://github.com/starknet-id/ens_resolver/blob/3577d3bf3e309614dbec16aca56b7cade2bac949/src/main.cairo#L7

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address pedersenAddress,
        address _starknetCoreContractAddress,
        string[] memory _gateways,
        uint256 _l2resolver
    ) public initializer {
        pedersen = PedersenHash(pedersenAddress);
        starknetCoreContract = StarknetCoreContract(
            _starknetCoreContractAddress
        );
        gateways = _gateways;
        l2resolver = _l2resolver;
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /************************************ENS Resolver Interface specific */

    function getl2Resolver() external view returns (uint256) {
        return l2resolver;
    }

    // returns the address of the storage within the starknet contract
    function calculateDomainStorageVarAddressFor(uint256 domain)
        internal
        view
        returns (uint256)
    {
        return hash(storageVarName, domain);
    }

    function addr(bytes32 node) public view returns (address) {
        return
            address(
                uint160(
                    _addr(node, StarknetVerifier.bytesAddrWithProof.selector)
                )
            );
    }

    function addr(bytes32 node, uint256 coinType)
        public
        view
        returns (bytes memory)
    {
        if (coinType == 60) {
            // replicated logic to demonstrate CCIP reslution on the ens app, as starknet address will not resolve so we are just resolving eth address.
            // 60 for eth address
            return
                uint256ToBytes(
                    _addr(node, StarknetVerifier.bytesAddrWithProof.selector)
                );
        } else if (coinType == 9004) {
            // 9004 for strk address
            return
                uint256ToBytes(
                    _addr(node, StarknetVerifier.bytesAddrWithProof.selector)
                );
        } else {
            return addressToBytes(address(0));
        }
    }

    function _addr(bytes32 node, bytes4 selector)
        private
        view
        returns (uint256)
    {
        uint256 starknetNode = uint256(node) & MASK_250;

        bytes memory callData = abi.encodeWithSelector(
            IStarknetResolverService.addr.selector,
            starknetNode
        );
        revert OffchainLookup(
            address(this),
            gateways,
            callData,
            selector,
            abi.encode(starknetNode)
        );
    }

    // function addrWithProof(bytes calldata response, bytes calldata extraData)
    //     external
    //     view
    //     returns (address)
    // {
    //     return _addrWithProof(response, extraData);
    // }

    function bytesAddrWithProof(
        bytes calldata response,
        bytes calldata extraData
    ) external view returns (bytes memory) {
        return uint256ToBytes(_addrWithProof(response, extraData));
    }

    function _addrWithProof(bytes calldata response, bytes calldata extraData)
        internal
        view
        returns (uint256)
    {
        StarknetCompositeStateProof memory proof = abi.decode(
            response,
            (StarknetCompositeStateProof)
        );
        bytes32 node = abi.decode(extraData, (bytes32));
        uint256 storageVarAdress = calculateDomainStorageVarAddressFor(
            uint256(node)
        );

        // update the storageVarAddress with the one we calculate here to make sure gateway has not returned a random storage var address/proof
        proof.contractData.contractAddress = l2resolver;
        proof.contractData.storageVarAddress = storageVarAdress;
        uint256 starknetAddress = this.verifiedStorageValue(
            proof.blockNumber,
            proof.contractData,
            proof.contractProofArray,
            proof.storageProofArray
        );

        return starknetAddress;
    }

    function supportsInterface(bytes4 interfaceID)
        public
        pure
        override
        returns (bool)
    {
        return
            interfaceID == ADDR_INTERFACE_ID ||
            interfaceID == ADDRESS_INTERFACE_ID;
    }

    function addressToBytes(address a) internal pure returns (bytes memory b) {
        b = new bytes(20);
        assembly {
            mstore(add(b, 32), mul(a, exp(256, 12)))
        }
    }

    function uint256ToBytes(uint256 x) private pure returns (bytes memory b) {
        b = new bytes(32);
        assembly {
            mstore(add(b, 32), x)
        }
    }

    /************************************ENS Resolver Interface specific END */

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    function hashForSingleProofNode(StarknetProof memory proof)
        public
        view
        returns (uint256)
    {
        uint256 hashvalue = 0;
        if (proof.nodeType == NodeType.BINARY) {
            hashvalue = hash(
                proof.binaryProof.leftHash,
                proof.binaryProof.rightHash
            );
        } else {
            hashvalue =
                (hash(proof.edgeProof.childHash, proof.edgeProof.path) +
                    uint256(proof.edgeProof.length)) %
                BIG_PRIME; // module big prime
        }
        return hashvalue;
    }

    // this functions connects the contract state root with value of leaf node in the contract proof.
    // state_hash = H(H(H(class_hash, contract_root), contract_nonce), RESERVED)
    function stateHash(
        uint256 classHash,
        uint256 contractStateRoot,
        uint256 nonce,
        uint256 hashVersion
    ) public view returns (uint256) {
        uint256 _stateHash = hash(
            hash(hash(classHash, contractStateRoot), nonce),
            hashVersion
        );
        return _stateHash;
    }

    function hash(uint256 a, uint256 b) public view returns (uint256) {
        // TO DO: check if this is correct, the zero index access is not cool
        uint256[] memory hashes = pedersen.hash(convertToBytes(a, b));

        require(hashes.length > 0, "hashes returned length is less than zero!");

        return hashes[0];
    }

    function convertToBytes(uint256 x, uint256 y)
        public
        pure
        returns (bytes memory)
    {
        bytes memory b = new bytes(64);
        assembly {
            mstore(add(b, 32), x)
        }
        assembly {
            mstore(add(b, 64), y)
        }

        return b;
    }

    // Verify the proof and return the value of the storage variable value otherwise revert.
    // Non-membership proof is not supported.
    // Only supports verifiying a proof for a single storage variable value.
    function verifiedStorageValue(
        int256 blockNumber,
        ContractData calldata contractData,
        StarknetProof[] calldata contractProofArray,
        StarknetProof[] calldata storageProofArray
    ) public view returns (uint256 value) {
        // There are two parts of the proof.
        // First part verifies the storage proof against the contract stateroot
        // and H(H(H(class_hash, contract_root), contract_nonce), RESERVED) should be the value(value in the leaf node) for the path in the contract proof.
        // Second part verifies the contract proof against the state root committed on L1 in the Starknet Core Contract
        console.log("stateRoot", starknetCoreContract.stateRoot());
        int256 coreStateBlockNumber = starknetCoreContract.stateBlockNumber();

        // proof array must have atleast one element
        require(
            contractProofArray.length > 0,
            "contract proofs must have atleast one element!"
        );

        require(
            storageProofArray.length > 0,
            "storage proofs must have atleast one element!"
        );

        // This is a safe assumption.
        require(
            coreStateBlockNumber > 0,
            "failed to fetch starknet core contract state block!"
        );

        require(
            blockNumber == coreStateBlockNumber,
            "block number doesn't match with starknet core contract!"
        );

        uint256 _stateHash = stateHash(
            contractData.classHash,
            contractData.contractStateRoot,
            contractData.nonce,
            contractData.hashVersion
        );

        uint256 storageVarValue = verifyProof(
            contractData.contractStateRoot,
            contractData.storageVarAddress,
            storageProofArray
        );

        // the contract proof has to be verified against the state root committed on L1 in the Starknet Core Contract
        uint256 stateRootCoreHash = starknetCoreContract.stateRoot();

        require(
            _stateHash != 0,
            "stateroot hash is not fetched properly! revert"
        );

        uint256 expectedStateHash = verifyProof(
            stateRootCoreHash,
            contractData.contractAddress,
            contractProofArray
        );

        require(
            _stateHash == expectedStateHash,
            "hashes don't match. invalid states!"
        );
        return storageVarValue;
    }

    // takes in two uint256 (a,b) values and returns true if the bits in the range [bitIndex, bitIndex + length - 1] of 'a' is equal to 'b' are equal.
    function compareBitsWithStartIndexAndLength(
        uint256 a,
        uint256 b,
        uint256 bitIndex,
        uint256 length
    ) public pure returns (bool) {
        uint256 msbitsToChopOff = 255 - bitIndex;
        uint256 aExtracted = ((a << msbitsToChopOff) >> msbitsToChopOff) >>
            (bitIndex - (length - 1));
        return aExtracted == b;
    }

    // A generic method to verify a proof against a root hash and a path.
    function verifyProof(
        uint256 rootHash,
        uint256 path,
        StarknetProof[] calldata proofArray
    ) public view returns (uint256 value) {
        uint256 expectedHash = rootHash;
        int256 pathBitIndex = 250; // start from the MSB bit index

        require(
            proofArray.length > 0,
            "proof array must have atleast one element."
        );

        bool isRight = true;
        for (uint256 i = 0; i < proofArray.length; i++) {
            if (pathBitIndex >= 0) {
                StarknetProof memory proof = proofArray[i];
                if (expectedHash != hashForSingleProofNode(proof)) {
                    revert(
                        "hash mismatch found!! invalid proof path reverting."
                    );
                }
                if (proof.nodeType == NodeType.BINARY) {
                    isRight = ((path >> uint256(pathBitIndex)) & 1) == 1;
                    // path = path & ~(1 << uint256(pathBitIndex));
                    // setting/clearing the bit as move through the path
                    if (isRight == true) {
                        expectedHash = proof.binaryProof.rightHash;
                    } else {
                        expectedHash = proof.binaryProof.leftHash;
                    }
                    pathBitIndex--;
                } else {
                    bool isPathEqual = compareBitsWithStartIndexAndLength(
                        path,
                        proof.edgeProof.path,
                        uint256(pathBitIndex),
                        proof.edgeProof.length
                    );
                    if (isPathEqual == false) {
                        revert(
                            "Invalid proof, potentially a proof for a different storage var/ non inclusion"
                        );
                    }
                    expectedHash = proof.edgeProof.childHash;
                    int256 edgePathLength = int256(proof.edgeProof.length);
                    pathBitIndex -= edgePathLength;
                    console.log("pathBitIndex", uint256(pathBitIndex));
                }
            }
        }
        // if the loop is complete and pathBitIndex is equal to -1 otherwise the proof is invalid
        if (pathBitIndex == -1) {
            return expectedHash;
        }
        revert("length of proof mismatched, invalid proof size!!");
    }
}