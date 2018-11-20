import * as R from 'ramda';
import * as Web3EthAbi from 'web3-eth-abi';

const query = functionName =>
  R.whereEq({ type: 'function', name: functionName });

const findFunctionDefinition = (abi: any, functionName: string) =>
  R.find(query(functionName))(abi);

export const getFunctionSignature = (abi: any, functionName: string) => {
  console.log('----- ', functionName);
  return Web3EthAbi.encodeFunctionSignature(
    findFunctionDefinition(abi, functionName),
  );
};
