// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "solmate/tokens/ERC20.sol";
import "solmate/tokens/ERC721.sol";
import "solmate/utils/MerkleProofLib.sol";
import "solmate/utils/SafeTransferLib.sol";
import "openzeppelin/utils/math/Math.sol";

import "./LpToken.sol";
import "./Caviar.sol";

/// @title Pair
/// @author out.eth (@outdoteth)
/// @notice A pair of an NFT and a base token that can be used to create and trade fractionalized NFTs.
contract Pair is ERC20, ERC721TokenReceiver {
    using SafeTransferLib for address;
    using SafeTransferLib for ERC20;

    uint256 public constant ONE = 1e18;
    uint256 public constant CLOSE_GRACE_PERIOD = 7 days;

    address public immutable nft;
    address public immutable baseToken; // address(0) for ETH
    bytes32 public immutable merkleRoot;
    LpToken public immutable lpToken;
    Caviar public immutable caviar;
    uint256 public closeTimestamp;

    event Add(
        uint256 baseTokenAmount,
        uint256 fractionalTokenAmount,
        uint256 lpTokenAmount
    );
    event Remove(
        uint256 baseTokenAmount,
        uint256 fractionalTokenAmount,
        uint256 lpTokenAmount
    );
    event Buy(uint256 inputAmount, uint256 outputAmount);
    event Sell(uint256 inputAmount, uint256 outputAmount);
    event Wrap(uint256[] tokenIds);
    event Unwrap(uint256[] tokenIds);
    event Close(uint256 closeTimestamp);
    event Withdraw(uint256 tokenId);

    constructor(
        address _nft,
        address _baseToken,
        bytes32 _merkleRoot,
        string memory pairSymbol,
        string memory nftName,
        string memory nftSymbol
    )
        ERC20(
            string.concat(nftName, " fractional token"),
            string.concat("f", nftSymbol),
            18
        )
    {
        nft = _nft;
        baseToken = _baseToken; // use address(0) for native ETH
        merkleRoot = _merkleRoot;
        lpToken = new LpToken(pairSymbol);
        caviar = Caviar(msg.sender);
    }

    // ************************ //
    //      Core AMM logic      //
    // ***********************  //

    /// ペアに流動性を追加する関数
    /// 引数 baseTokenAmount 追加するベーストークンの量
    /// 引数 fractionalTokenAmount 追加するフラクショナルトークンの量
    /// 引数 minLpTokenAmount ミントするLPトークンの最小量
    /// 戻り値 lpTokenAmount ミントされたLPトークンの量
    function add(
        uint256 baseTokenAmount,
        uint256 fractionalTokenAmount,
        uint256 minLpTokenAmount
    ) public payable returns (uint256 lpTokenAmount) {
        // *** Checks *** //

        //引数のbaseTokenAmount、fractionalTokenAmountが0より大きければパス
        require(
            baseTokenAmount > 0 && fractionalTokenAmount > 0,
            "Input token amount is zero"
        );

        //ベーストークンがイーサなら
        //引数のベーストークン量とmsg.valueが一緒であればパス
        //ベーストークンがイーサでないなら
        //msg.valueが0ならパス
        require(
            baseToken == address(0)
                ? msg.value == baseTokenAmount
                : msg.value == 0,
            "Invalid ether input"
        );

        //ミントされるべきLPトークンの量をbaseTokenAmountとfractionalTokenAmountから算出
        lpTokenAmount = addQuote(baseTokenAmount, fractionalTokenAmount);

        //上で算出されたlpTokenAmountが、引数のminLpTokenAmount以上ならパス
        require(
            lpTokenAmount >= minLpTokenAmount,
            "Slippage: lp token amount out"
        );

        // *** Effects *** //

        //フラクショナルトークンをこのコントラクトからLP（流動性提供者）に送信
        _transferFrom(msg.sender, address(this), fractionalTokenAmount);

        // *** Interactions *** //

        //LPにLPトークンをミントする
        lpToken.mint(msg.sender, lpTokenAmount);

        // ベーストークンがイーサでないなら
        // LPのベーストークンを、このコントラクトに移す
        if (baseToken != address(0)) {
            // transfer base tokens in
            ERC20(baseToken).safeTransferFrom(
                msg.sender,
                address(this),
                baseTokenAmount
            );
        }

        emit Add(baseTokenAmount, fractionalTokenAmount, lpTokenAmount);
    }

    /// ペアから流動性を削除する関数
    /// 引数 lpTokenAmount バーンされるLPトークンの量
    /// 引数 minBaseTokenOutputAmount 受け取るベーストークンの最小量
    /// 引数 minFractionalTokenOutputAmount 受け取るフラクショナルトークンの最小量
    /// 戻り値 baseTokenOutputAmount 受け取ったベーストークンの量
    /// 戻り値 fractionalTokenOutputAmount 受け取ったフラクショナルトークンの量
    function remove(
        uint256 lpTokenAmount,
        uint256 minBaseTokenOutputAmount,
        uint256 minFractionalTokenOutputAmount
    )
        public
        returns (
            uint256 baseTokenOutputAmount,
            uint256 fractionalTokenOutputAmount
        )
    {
        // *** Checks *** //

        //LPに返されるベーストークンとフラクショナルトークンの量を、LPトークンの量から算出
        (baseTokenOutputAmount, fractionalTokenOutputAmount) = removeQuote(
            lpTokenAmount
        );

        //上で算出された返されるベーストークンの量が、引数のminBaseTokenOutputAmount以上ならパス
        require(
            baseTokenOutputAmount >= minBaseTokenOutputAmount,
            "Slippage: base token amount out"
        );

        //上で算出された返されるフラクショナルトークンの量が、引数のminFractionalTokenOutputAmount以上ならパス
        require(
            fractionalTokenOutputAmount >= minFractionalTokenOutputAmount,
            "Slippage: fractional token out"
        );

        // *** Effects *** //

        // LPにこのコントラクトからフラクショナルトークンを送信
        _transferFrom(address(this), msg.sender, fractionalTokenOutputAmount);

        // *** Interactions *** //

        //LPのLPトークンをバーンする
        lpToken.burn(msg.sender, lpTokenAmount);

        //ベーストークンがイーサなら
        if (baseToken == address(0)) {
            //LPにイーサを送信
            msg.sender.safeTransferETH(baseTokenOutputAmount);
            //ベーストークンがERC20なら
        } else {
            //LPにERC20を送信
            ERC20(baseToken).safeTransfer(msg.sender, baseTokenOutputAmount);
        }

        emit Remove(
            baseTokenOutputAmount,
            fractionalTokenOutputAmount,
            lpTokenAmount
        );
    }

    /// ペアからフラクショナルトークンを買う関数
    /// 引数 outputAmount 買うフラクショナルトークンの量
    /// 引数 maxInputAmount 送るベーストークンの最大量
    /// 戻り値 inputAmount 送ったベーストークンの量
    function buy(uint256 outputAmount, uint256 maxInputAmount)
        public
        payable
        returns (uint256 inputAmount)
    {
        // *** Checks *** //

        //ベーストークンがイーサなら
        //msg.valueと引数のmaxInputAmountが一緒であればパス
        //ベーストークンがERC20なら
        //msg.valueが0であればパス
        require(
            baseToken == address(0)
                ? msg.value == maxInputAmount
                : msg.value == 0,
            "Invalid ether input"
        );

        //引数のoutputAmountで指定された量のフラクショナルトークンを買うのに必要なベーストークンを算出
        //計算式は、k(不変量) = x*y
        inputAmount = buyQuote(outputAmount);

        //上で算出されたinputAmountが、maxInputAmount以下ならパス
        require(inputAmount <= maxInputAmount, "Slippage: amount in");

        // *** Effects *** //

        //買い手にこのコントラクトからフラクショナルトークンを送信
        _transferFrom(address(this), msg.sender, outputAmount);

        // *** Interactions *** //

        //ベーストークンがイーサなら
        if (baseToken == address(0)) {
            //余りを返す
            //maxInputAmount - inputAmountで返却するイーサを算出
            uint256 refundAmount = maxInputAmount - inputAmount;
            //上の式の解が0より大きければ、余ったイーサを買い手に返却
            if (refundAmount > 0) msg.sender.safeTransferETH(refundAmount);
            //ベーストークンがERC20なら
        } else {
            //買い手のベーストークンをこのコントラクトに移す
            ERC20(baseToken).safeTransferFrom(
                msg.sender,
                address(this),
                inputAmount
            );
        }

        emit Buy(inputAmount, outputAmount);
    }

    /// ペアにフラクショナルトークンを売る関数
    /// 引数 inputAmount 売るフラクショナルトークンの量
    /// 引数 minOutputAmount 受け取るベーストークンの最小量
    /// 戻り値 outputAmount 受け取ったベーストークンの量
    function sell(uint256 inputAmount, uint256 minOutputAmount)
        public
        returns (uint256 outputAmount)
    {
        // *** Checks *** //

        //売られるフラクショナルトークンの量からベーストークンの量をk(不変量)=x*yで算出
        outputAmount = sellQuote(inputAmount);

        //上で算出されたベーストークンの量が引数のminOutputAmount以上ならパス
        require(outputAmount >= minOutputAmount, "Slippage: amount out");

        // *** Effects *** //

        //売り手からこのコントラクトにフラクショナルトークンを移す
        _transferFrom(msg.sender, address(this), inputAmount);

        // *** Interactions *** //

        //ベーストークンがイーサなら
        if (baseToken == address(0)) {
            //売り手にイーサを送信
            msg.sender.safeTransferETH(outputAmount);
            //ベーストークンがERC20なら
        } else {
            // transfer base tokens out
            //売り手にERC20を送信
            ERC20(baseToken).safeTransfer(msg.sender, outputAmount);
        }

        emit Sell(inputAmount, outputAmount);
    }

    // ******************** //
    //      Wrap logic      //
    // ******************** //

    /// NFTをフラクショナルトークンにラップする関数
    /// 引数 tokenIds ラップするNFTのID
    /// 引数 proofs ペアで使用することができることを示しているNFTのマークルプルーフ
    /// 戻り値 fractionalTokenAmount ミントされたフラクショナルトークンの量
    function wrap(uint256[] calldata tokenIds, bytes32[][] calldata proofs)
        public
        returns (uint256 fractionalTokenAmount)
    {
        // *** Checks *** //

        //ペアのプールが閉じられていなければパス
        require(closeTimestamp == 0, "Wrap: closed");

        //マークルルートの中に当該NFTがあればパス
        _validateTokenIds(tokenIds, proofs);

        // *** Effects *** //

        //ラップされるNFTの数 × 1をミントされるフラクショナルトークンの量として算出
        fractionalTokenAmount = tokenIds.length * ONE;
        //上で算出されたフラクショナルトークンをLPにミントする
        _mint(msg.sender, fractionalTokenAmount);

        // *** Interactions *** //

        //LPからこのコントラクトにNFTを移す（NFTの数だけ）
        for (uint256 i = 0; i < tokenIds.length; i++) {
            ERC721(nft).safeTransferFrom(
                msg.sender,
                address(this),
                tokenIds[i]
            );
        }

        emit Wrap(tokenIds);
    }

    /// NFTのラップを解除してフラクショナルトークンをNFTに戻す関数
    /// 引数 tokenIds ラップが解除されるNFTのID
    /// 戻り値 fractionalTokenAmount バーンされるフラクショナルトークンの量
    function unwrap(uint256[] calldata tokenIds)
        public
        returns (uint256 fractionalTokenAmount)
    {
        // *** Effects *** //

        //バーンされるフラクショナルトークンの量を、NFTの数 × 1として算出
        fractionalTokenAmount = tokenIds.length * ONE;
        //上で算出されたフラクショナルトークンの量をバーン
        _burn(msg.sender, fractionalTokenAmount);

        // *** Interactions *** //

        //LPにNFTを返却（NFTの数だけ）
        for (uint256 i = 0; i < tokenIds.length; i++) {
            ERC721(nft).safeTransferFrom(
                address(this),
                msg.sender,
                tokenIds[i]
            );
        }

        emit Unwrap(tokenIds);
    }

    // *********************** //
    //      NFT AMM logic      //
    // *********************** //

    /// nftAdd ペアに流動性を追加する（プールにベーストークンとNFTを入れる）関数
    /// 引数 baseTokenAmount ペアに入れるベーストークンの量
    /// 引数 tokenIds ペアに入れるNFTのID
    /// 引数 minLpTokenAmount LPが受け取るLPトークンの最小量
    /// 引数 proofs NFTのマークルプルーフ
    /// 戻り値 lpTokenAmount ミントされるLPトークンの量
    function nftAdd(
        uint256 baseTokenAmount,
        uint256[] calldata tokenIds,
        uint256 minLpTokenAmount,
        bytes32[][] calldata proofs
    ) public payable returns (uint256 lpTokenAmount) {
        //NFTをラップしてフラクショナルトークンをミントする。ミントしたトークンの量をfractionalTokenAmountに代入
        uint256 fractionalTokenAmount = wrap(tokenIds, proofs);

        //ベーストークンとフラクショナルトークンの量からLPトークンを算出して返り値に入れる
        lpTokenAmount = add(
            baseTokenAmount,
            fractionalTokenAmount,
            minLpTokenAmount
        );
    }

    /// Removes ペアから流動性を取り除く関数
    /// 引数 lpTokenAmount 取り除くLPトークンの量
    /// 引数 minBaseTokenOutputAmount LPが受け取るベーストークンの最小量
    /// 引数 tokenIds ペアから取り除くNFTのID
    /// 戻り値 baseTokenOutputAmount LPが受け取ったベーストークンの量
    /// 戻り値 fractionalTokenOutputAmount LPが受け取ったフラクショナルトークンの量
    function nftRemove(
        uint256 lpTokenAmount,
        uint256 minBaseTokenOutputAmount,
        uint256[] calldata tokenIds
    )
        public
        returns (
            uint256 baseTokenOutputAmount,
            uint256 fractionalTokenOutputAmount
        )
    {
        //流動性を取り除いて、LPにフラクショナルトークンとベーストークンを送信
        (baseTokenOutputAmount, fractionalTokenOutputAmount) = remove(
            lpTokenAmount,
            minBaseTokenOutputAmount,
            tokenIds.length * ONE
        );

        //フラクショナルトークンをアンラップしてNFTにし、そのNFTをLPに返却する
        unwrap(tokenIds);
    }

    /// ベーストークンを使用して、ペアからNFTを買う関数
    /// 引数 tokenIds 買うNFTのID
    /// 引数 maxInputAmount 買い手が送るベーストークンの最大量
    /// 戻り値 inputAmount 買い手が送ったベーストークンの量
    function nftBuy(uint256[] calldata tokenIds, uint256 maxInputAmount)
        public
        payable
        returns (uint256 inputAmount)
    {
        //ベーストークンでフラクショナルトークンを買う
        inputAmount = buy(tokenIds.length * ONE, maxInputAmount);

        // unwrap the fractional tokens into NFTs and send to sender
        // フラクショナルトークンをアンラップしてNFTにし、買い手にそのNFTを送る
        unwrap(tokenIds);
    }

    /// ベーストークンのペアにNFTを売る関数
    /// 引数 tokenIds 売り手が売るNFTのID
    /// 引数 minOutputAmount 売り手が受け取るベーストークンの最小量
    /// 引数 proofs 売られるNFTのマークルプルーフ
    /// 戻り値 outputAmount 売り手が受け取ったベーストークンの量
    function nftSell(
        uint256[] calldata tokenIds,
        uint256 minOutputAmount,
        bytes32[][] calldata proofs
    ) public returns (uint256 outputAmount) {
        //NFTをラップしてフラクショナルトークンにする
        uint256 inputAmount = wrap(tokenIds, proofs);

        // sell fractional tokens for base tokens
        //ベーストークンに対するフラクショナルトークンを売り手に送る？
        //ベーストークンを売り手に送るんじゃない？
        outputAmount = sell(inputAmount, minOutputAmount);
    }

    // ****************************** //
    //      Emergency exit logic      //
    // ****************************** //

    /// ラップをするためのペアを閉じる関数
    /// キャビアオーナーのみ実行可能。
    //フラクショナルトークンの供給量が1に満たなくなり、オーナーがそれを妥当とした場合、
    //オーナーによってペアは閉じられる
    function close() public {
        //関数の呼び出しがオーナーならパス
        require(caviar.owner() == msg.sender, "Close: not owner");

        //現時刻に1週間を加算して、closeTimestampに記録
        closeTimestamp = block.timestamp + CLOSE_GRACE_PERIOD;

        //キャビアコントラクトからペアを削除（マッピングをdelete）
        caviar.destroy(nft, baseToken, merkleRoot);

        emit Close(closeTimestamp);
    }

    /// ペアから特定のNFTを引き出す関数
    /// ペアが閉じられてから一週間後に、キャビアオーナーのみ実行可能。
    //流動性の均衡が破れたことでペア内にスタックしてしまったNFTをオークションに出品する際に使用される
    //オークションからの収益は、フラクショナルトークン保有者に比例分配される
    function withdraw(uint256 tokenId) public {
        //関数の呼び出しがキャビアオーナーならパス
        require(caviar.owner() == msg.sender, "Withdraw: not owner");

        //closeTimestampが設定されていればパス（0でなければ設定済み）
        require(closeTimestamp != 0, "Withdraw not initiated");

        //ペアが閉じられてから一週間以上が経過していればパス
        require(block.timestamp >= closeTimestamp, "Not withdrawable yet");

        //当該NFTをこのコントラクトからオーナーに送る
        ERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdraw(tokenId);
    }

    // ***************** //
    //      Getters      //
    // ***************** //

    function baseTokenReserves() public view returns (uint256) {
        return _baseTokenReserves();
    }

    function fractionalTokenReserves() public view returns (uint256) {
        return balanceOf[address(this)];
    }

    /// 1フラクショナルトークンあたりのベーストークンの直近の価格（小数点以下18桁まで）を求める関数
    //ベーストークンの最低価格をフラクショナルトークンの最低価格で割って算出
    /// 戻り値 price 除算したものに1e18を掛けて、返す
    function price() public view returns (uint256) {
        return (_baseTokenReserves() * ONE) / fractionalTokenReserves();
    }

    /// 指定された量のフラクショナルトークンを買うのに必要なベーストークンを算出する関数
    //計算にはxykの等式と3%の手数料が使われる
    /// 引数 outputAmount 買うフラクショナルトークンの量
    /// 戻り値 inputAmount 必要なベーストークンの量
    function buyQuote(uint256 outputAmount) public view returns (uint256) {
        return
            (outputAmount * 1000 * baseTokenReserves()) /
            ((fractionalTokenReserves() - outputAmount) * 997);
    }

    /// 指定された量のフラクショナルトークンを売るために受け取ったベーストークンの量を算出する関数
    //計算にはxykの等式と3%の手数料が使われる
    /// 引数 inputAmount 売るフラクショナルトークンの量
    /// 戻り値 outputAmount 受け取ったベーストークンの量
    function sellQuote(uint256 inputAmount) public view returns (uint256) {
        uint256 inputAmountWithFee = inputAmount * 997;
        return
            (inputAmountWithFee * baseTokenReserves()) /
            ((fractionalTokenReserves() * 1000) + inputAmountWithFee);
    }

    /// 指定されたベーストークンとフラクショナルトークンの量からLPが受け取るLPトークンの量を算出する関数
    //計算は、存在するデポジットの分け前として算出
    //デポジットが存在していなければ、baseTokenAmount * fractionalTokenAmountの平方根を初期値とする。
    /// 引数 baseTokenAmount 追加するベーストークンの量
    /// 引数 fractionalTokenAmount 追加するフラクショナルトークンの量
    /// 戻り値 lpTokenAmount ミントすべきLPトークンの量
    function addQuote(uint256 baseTokenAmount, uint256 fractionalTokenAmount)
        public
        view
        returns (uint256)
    {
        //LPトークンの総供給量
        uint256 lpTokenSupply = lpToken.totalSupply();
        //LPトークンの総供給量が0より大きければ
        if (lpTokenSupply > 0) {
            // calculate amount of lp tokens as a fraction of existing reserves
            uint256 baseTokenShare = (baseTokenAmount * lpTokenSupply) /
                baseTokenReserves();
            uint256 fractionalTokenShare = (fractionalTokenAmount *
                lpTokenSupply) / fractionalTokenReserves();
            return Math.min(baseTokenShare, fractionalTokenShare);
            //LPトークンがまだ供給されていなければ
        } else {
            // baseTokenAmount * fractionalTokenAmountの平方根を初期値として返す
            return Math.sqrt(baseTokenAmount * fractionalTokenAmount);
        }
    }

    /// 指定された量のLPトークンをバーンして、LPが受け取るベーストークンとフラクショナルトークンの量を算出する関数
    //計算は、存在するデポジットの分け前として算出
    /// 引数 lpTokenAmount バーンするLPトークンの量
    /// 戻り値 baseTokenAmount LPに返すべきベーストークンの量
    /// 戻り値 fractionalTokenAmount LPに返すべきフラクショナルトークンの量
    function removeQuote(uint256 lpTokenAmount)
        public
        view
        returns (uint256, uint256)
    {
        uint256 lpTokenSupply = lpToken.totalSupply();
        uint256 baseTokenOutputAmount = (baseTokenReserves() * lpTokenAmount) /
            lpTokenSupply;
        uint256 fractionalTokenOutputAmount = (fractionalTokenReserves() *
            lpTokenAmount) / lpTokenSupply;

        return (baseTokenOutputAmount, fractionalTokenOutputAmount);
    }

    // ************************ //
    //      Internal utils      //
    // ************************ //

    function _transferFrom(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /// 指定されたNFTのIDが、コントラクトのマークルルートに存在するか検証する関数
    //NFTのIDが存在しなかったら、元に戻す
    function _validateTokenIds(
        uint256[] calldata tokenIds,
        bytes32[][] calldata proofs
    ) internal view {
        // if merkle root is not set then all tokens are valid
        //マークルルートが設定されてたらパス
        if (merkleRoot == bytes23(0)) return;

        // validate merkle proofs against merkle root
        // ライブラリを使用して検証する
        for (uint256 i = 0; i < tokenIds.length; i++) {
            bool isValid = MerkleProofLib.verify(
                proofs[i],
                merkleRoot,
                keccak256(abi.encodePacked(tokenIds[i]))
            );
            require(isValid, "Invalid merkle proof");
        }
    }

    /// 直近のベーストークンの最低価格を返す関数
    // ベーストークンがイーサなら、直近のコールコンテクスト（引数）で送られたmsg.valueは無視する。そのために差し引く。
    // これにより、buy関数とadd関数で使用されるk=x*yの計算が担保される。
    function _baseTokenReserves() internal view returns (uint256) {
        /*
         ベーストークンがイーサなら
         このコントラクトの残高からmsg.valueを差し引いて、返す
         ベーストークンがERC20なら
         このコントラクトのベーストークンの残高を返す
         */
        return
            baseToken == address(0)
                ? address(this).balance - msg.value // subtract the msg.value if the base token is ETH
                : ERC20(baseToken).balanceOf(address(this));
    }
}
