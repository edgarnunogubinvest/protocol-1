const {nab, send} = require('./deploy-contract');
const web3 = require('./get-web3');
const BN = web3.utils.BN;

const main = async input => {
  const tokenAddrs = input.tokens.addr;
  const weth = await nab('WETH', [], tokenAddrs);
  const mln = await nab('BurnableToken', ['MLN', 18, 'Melon Token'], tokenAddrs, 'MLN');
  const bat = await nab('PreminedToken', ['BAT', 18, ''], tokenAddrs, 'BAT');
  const dai = await nab('PreminedToken', ['DAI', 18, ''], tokenAddrs, 'DAI');
  const dgx = await nab('PreminedToken', ['DGX', 18, ''], tokenAddrs, 'DGX');
  const eur = await nab('PreminedToken', ['EUR', 18, ''], tokenAddrs, 'EUR');
  const knc = await nab('PreminedToken', ['KNC', 18, ''], tokenAddrs, 'KNC');
  const mkr = await nab('PreminedToken', ['MKR', 18, ''], tokenAddrs, 'MKR');
  const rep = await nab('PreminedToken', ['REP', 18, ''], tokenAddrs, 'REP');
  const zrx = await nab('PreminedToken', ['ZRX', 18, ''], tokenAddrs, 'ZRX');

  const depositAmount = (new BN('10')).pow(new BN('24'));
  await send(weth, 'deposit', [], {value: depositAmount});

  return {
    "WETH": weth,
    "MLN": mln,
    "BAT": bat,
    "DAI": dai,
    "DGX": dgx,
    "EUR": eur,
    "KNC": knc,
    "MKR": mkr,
    "REP": rep,
    "ZRX": zrx,
  };
}

module.exports = main;