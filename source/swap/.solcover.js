module.exports = {
    port: 8545,
    norpc: false,
    testrpcOptions: '--time "2017-05-10T00:00:00+00:00"',
    compileCommand: 'truffle compile',
    testCommand: 'truffle test --network coverage',
    skipFiles: ['analysis', 'interfaces', 'contracts/Imports.sol'],
    compilers: {
        solc: {
          evmVersion: "istanbul",
          version: "0.5.13" // A version or constraint - Ex. "^0.5.0"
        }
    }
};
