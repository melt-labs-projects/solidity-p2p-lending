async function main(){
    const [deployer] = await ethers.getSigners();
    console.log(deployer.address);

    const balance = await deployer.getBalance();
    console.log(balance.toString());

    const Token = await ethers.getContractFactory('MainController');
    const token = await Token.deploy();
    console.log(token.address);
}

main().then(() => process.exit(0)).catch(e => {console.log(e)});