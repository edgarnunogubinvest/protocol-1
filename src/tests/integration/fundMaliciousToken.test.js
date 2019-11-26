import { BN, toWei } from 'web3-utils';

import { initTestEnvironment } from '~/tests/utils/initTestEnvironment';
import { stringToBytes } from '../utils/new/formatting';
import { deployContract } from '~/utils/solidity/deployContract';
import { getContract } from '~/utils/solidity/getContract';
import { deployAndGetSystem } from '../utils/deployAndGetSystem';
import { CONTRACT_NAMES } from '../utils/new/constants';
const getFundComponents = require('../utils/new/getFundComponents');
const updateTestingPriceFeed = require('../utils/new/updateTestingPriceFeed');
const {deploy, fetchContract} = require('../../../new/deploy/deploy-contract');
const web3 = require('../../../new/deploy/get-web3');
const deploySystem = require('../../../new/deploy/deploy-system');

describe('fund-malicious-token', () => {
  let accounts;
  let defaultTxOpts, investorTxOpts, managerTxOpts;
  let deployer, manager, investor;
  let contracts, deployOut;
  let fund, weth, mln, registry, version, maliciousToken;

  beforeAll(async () => {
    accounts = await web3.eth.getAccounts();
    [deployer, manager, investor] = accounts;
    defaultTxOpts = { from: deployer, gas: 8000000 };
    managerTxOpts = { ...defaultTxOpts, from: manager };
    investorTxOpts = { ...defaultTxOpts, from: investor };

    const deployment = await deploySystem(JSON.parse(require('fs').readFileSync(process.env.CONF))); // TODO: change from reading file each time
    contracts = deployment.contracts;
    deployOut = deployment.deployOut;
    weth = contracts.WETH;
    mln = contracts.MLN;
    registry = contracts.Registry;
    version = contracts.Version;

    maliciousToken = await deploy(
      CONTRACT_NAMES.MALICIOUS_TOKEN,
      ['MLC', 18, 'Malicious']
    );

    await registry.methods
      .registerAsset(
        maliciousToken.options.address.toLowerCase(),
        'Malicious',
        'MLC',
        '',
        0,
        [],
        [],
      )
      .send(defaultTxOpts);

    await version.methods
      .beginSetup(
        stringToBytes('Test fund', 32),
        [],
        [],
        [],
        [],
        [],
        weth.options.address.toString(),
        [
          mln.options.address.toString(),
          weth.options.address.toString(),
          maliciousToken.options.address.toString(),
        ],
      )
      .send(managerTxOpts);

    await version.methods.createAccounting().send(managerTxOpts);
    await version.methods.createFeeManager().send(managerTxOpts);
    await version.methods.createParticipation().send(managerTxOpts);
    await version.methods.createPolicyManager().send(managerTxOpts);
    await version.methods.createShares().send(managerTxOpts);
    await version.methods.createTrading().send(managerTxOpts);
    await version.methods.createVault().send(managerTxOpts);
    const res = await version.methods.completeSetup().send(managerTxOpts);
    const hubAddress = res.events.NewFund.returnValues.hub;

    fund = await getFundComponents(hubAddress);
    await updateTestingPriceFeed(contracts.TestingPriceFeed, Object.values(deployOut.tokens.addr));
  });

  test('investor gets initial ethToken for testing)', async () => {
    const initialTokenAmount = toWei('10', 'ether');

    const preWethInvestor = await weth.methods.balanceOf(investor).call();
    await weth.methods
      .transfer(investor, initialTokenAmount)
      .send(defaultTxOpts);
    const postWethInvestor = await weth.methods.balanceOf(investor).call();

    expect(new BN(postWethInvestor.toString()))
      .toEqualBN(new BN(preWethInvestor.toString()).add(new BN(initialTokenAmount.toString())));
  });

  test('fund receives ETH from investment', async () => {
    const offeredValue = toWei('1', 'ether');
    const wantedShares = toWei('1', 'ether');
    const amguAmount = toWei('.01', 'ether');

    const preWethFund = await weth.methods
      .balanceOf(fund.vault.options.address)
      .call();
    const preWethInvestor = await weth.methods.balanceOf(investor).call();

    await weth.methods
      .approve(fund.participation.options.address, offeredValue)
      .send(investorTxOpts);
    await fund.participation.methods
      .requestInvestment(offeredValue, wantedShares, weth.options.address)
      .send({ ...investorTxOpts, value: amguAmount });
    await fund.participation.methods
      .executeRequestFor(investor)
      .send(investorTxOpts);

    const postWethFund = await weth.methods
      .balanceOf(fund.vault.options.address)
      .call();
    const postWethInvestor = await weth.methods.balanceOf(investor).call();

    expect(new BN(postWethInvestor.toString()))
      .toEqualBN(new BN(preWethInvestor.toString()).sub(new BN(offeredValue.toString())));
    expect(new BN(postWethFund.toString()))
      .toEqualBN(new BN(preWethFund.toString()).add(new BN(offeredValue.toString())));
  });

  test(`General redeem fails in presence of malicious token`, async () => {
    const { vault, participation } = fund;

    await maliciousToken.methods
      .transfer(vault.options.address, 1000000)
      .send(defaultTxOpts);
    await maliciousToken.methods.startReverting().send(defaultTxOpts);

    expect(
      participation.methods.redeem().send(investorTxOpts),
    ).rejects.toThrow();
  });

  test(`Redeem with constraints works as expected`, async () => {
    const { accounting, participation, shares, vault } = fund;

    const preMlnFund = await mln.methods
      .balanceOf(vault.options.address)
      .call();
    const preMlnInvestor = await mln.methods.balanceOf(investor).call();
    const preWethFund = await weth.methods
      .balanceOf(vault.options.address)
      .call();
    const preWethInvestor = await weth.methods.balanceOf(investor).call();
    const investorShares = await shares.methods.balanceOf(investor).call();
    const preTotalSupply = await shares.methods.totalSupply().call();

    await participation.methods
      .redeemWithConstraints(investorShares, [weth.options.address])
      .send(investorTxOpts);

    const postMlnFund = await mln.methods
      .balanceOf(vault.options.address)
      .call();
    const postMlnInvestor = await mln.methods.balanceOf(investor).call();
    const postWethFund = await weth.methods
      .balanceOf(vault.options.address)
      .call();
    const postWethInvestor = await weth.methods.balanceOf(investor).call();
    const postTotalSupply = await shares.methods.totalSupply().call();
    const postFundGav = await accounting.methods.calcGav().call();

    expect(new BN(postTotalSupply.toString()))
      .toEqualBN(new BN(preTotalSupply.toString()).sub(new BN(investorShares.toString())));
      expect(new BN(postWethInvestor.toString()))
        .toEqualBN(new BN(preWethInvestor.toString()).add(new BN(preWethFund.toString())));
    expect(new BN(postWethFund.toString())).toEqualBN(new BN(0));
    expect(postMlnFund).toEqual(preMlnFund);
    expect(postMlnInvestor).toEqual(preMlnInvestor);
    expect(new BN(postFundGav.toString())).toEqualBN(new BN(0));
  });
});