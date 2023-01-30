import { ethers, upgrades } from "hardhat";
import fs from "fs";
import * as dotenv from "dotenv";
import path from "path";

dotenv.config();

const deployTables = async () => {
  let precomputedContracts: any[64] = [];
  for (const i in new Array(64).fill(0)) {
    const generatedPath = path.join(__dirname, "..", "generated");

    const bytecodePath = path.join(generatedPath, `${i}.bytecode`);
    const bytecode = fs.readFileSync(bytecodePath);

    const ContractCodePrecomputed = await ethers.getContractFactory(
      "ContractCodePrecomputed"
    );
    const factory = new ethers.ContractFactory(
      ContractCodePrecomputed.interface,
      bytecode.toString(),
      ContractCodePrecomputed.signer
    );

    console.log("Deploying contract: ", i);
    const contract = await factory.deploy();
    precomputedContracts.push(contract);
    await contract.deployed();
    console.log("Contract deployed: ", contract.address);
  }
  return precomputedContracts;
};

const deployAll = async () => {
  let pedersenHash: any;
  let proofverifier: any;
  let starknetCoreContractStub: any;

  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());

  try {
    const StarknetVerifier = await ethers.getContractFactory(
      "StarknetVerifier"
    );
    const network = await ethers.provider.getNetwork();

    console.log("Network: ", network.name);
    if (network.name == "goerli") {
      console.log("Deploying to Goerli");
      // proofverifier = await StarknetVerifier.deploy('0x1a1eB562D2caB99959352E40a03B52C00ba7a5b1', '0xde29d060D45901Fb19ED6C6e959EB22d8626708e');
      // proofverifier = await StarknetVerifier.deploy();
      const proofProxy = await upgrades.deployProxy(
        StarknetVerifier,
        [
          "0x1a1eB562D2caB99959352E40a03B52C00ba7a5b1",
          "0xde29d060D45901Fb19ED6C6e959EB22d8626708e",
          ["https://starknetens.ue.r.appspot.com/{sender}/{data}.json"], // per https://eips.ethereum.org/EIPS/eip-3668  the sender and data populated by the client library like ethers.js with data returned by the CCIP enabled contract via revert
          '0x7412b9155cdb517c5d24e1c80f4af96f31f221151aab9a9a1b67f380a349ea3'
        ],
        { deployer }
      );
      proofverifier = await proofProxy.deployed();
    } else if (network.name == "mainnet") {
      console.log("Deploying to Mainnet");
      // TODO: Add mainnet address
      // proofverifier = await StarknetVerifier.deploy(
      //   "XXXXXXX",
      //   "0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4"
      // );
    } else {
      console.log("Deploying to Localhost");
      const contracts = await deployTables();

      const PedersenHash = await ethers.getContractFactory("PedersenHash");
      pedersenHash = await PedersenHash.deploy(
        contracts.map((c: any) => c.address as string)
      );
      await pedersenHash.deployed();
      console.log(
        "PedersenHash contract has been deployed to: ",
        pedersenHash.address
      );

      const StarknetCoreContractStub = await ethers.getContractFactory(
        "StarknetCoreContractStub"
      );
      starknetCoreContractStub = await StarknetCoreContractStub.deploy();
      await starknetCoreContractStub.deployed();

      console.log(
        "StarknetCoreContractStub contract has been deployed to: ",
        starknetCoreContractStub.address
      );

      const proofProxy = await upgrades.deployProxy(
        StarknetVerifier,
        [pedersenHash.address, starknetCoreContractStub.address, ["https://localhost:9545/{sender}/{data}.json"], '0x7412b9155cdb517c5d24e1c80f4af96f31f221151aab9a9a1b67f380a349ea3'],
        { deployer }
      );
      proofverifier = await proofProxy.deployed();
    }

    console.log(
      "Verifier contract has been deployed to: ",
      proofverifier.address
    );
  } catch (e) {
    console.log(e);
  }
};

deployAll();
