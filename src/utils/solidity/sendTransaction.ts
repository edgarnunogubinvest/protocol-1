import { getGlobalEnvironment } from '~/utils/environment';

const debug = require('~/utils/getDebug').default(__filename);

export const sendTransaction = async (
  prepared,
  environment = getGlobalEnvironment(),
) => {
  debug('Sending transaction: ', prepared.name);

  // TODO: Error handling
  const receipt = await prepared.transaction.send({
    from: environment.wallet.address,
    // TODO: Check for DELEGATE_CALL or LIBRARY
    gas: Math.floor(prepared.gasEstimation * 1.2).toString(),
    gasPrice: environment.options.gasPrice,
  });

  debug('TX Receipt', receipt);

  return receipt;
};
