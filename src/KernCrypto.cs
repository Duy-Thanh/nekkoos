namespace NekkoOS.Kernel.Crypto;

// ==========================================================
// [VŨ KHÍ TỐI THƯỢNG] BAREMETAL SHA-256 CRYPTO ENGINE (RING 3)
// Bản sao từ src/Boot.cs (NekkoOS.BaremetalSHA256) - tách riêng để dùng
// chung cho các app Ring 3 (Login.exe, và các tool xác thực khác trong
// tương lai như passwd/useradd) mà không phải copy-paste lại thuật toán.
// Chạy hoàn toàn bằng stack, không đụng Heap.
// ==========================================================
public static unsafe class SHA256
{
    private static uint ROTR(uint x, int n) => (x >> n) | (x << (32 - n));
    private static uint CH(uint x, uint y, uint z) => (x & y) ^ (~x & z);
    private static uint MAJ(uint x, uint y, uint z) => (x & y) ^ (x & z) ^ (y & z);
    private static uint EP0(uint x) => ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22);
    private static uint EP1(uint x) => ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25);
    private static uint SIG0(uint x) => ROTR(x, 7) ^ ROTR(x, 18) ^ (x >> 3);
    private static uint SIG1(uint x) => ROTR(x, 17) ^ ROTR(x, 19) ^ (x >> 10);

    private static readonly uint[] SHA256_K = new uint[64] {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    };

    private static readonly uint[] SHA256_H0 = new uint[8] { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };

    public static void Compute(byte* data, ulong length, byte* outputHash)
    {
        if (data == null || outputHash == null || length == 0)
            return;

        // Giới hạn kích thước đầu vào để tránh tràn bộ nhớ
        if (length > 0x10000000) // 256MB
            return;

        fixed (uint* Kptr = SHA256_K)
        {
            uint* H = stackalloc uint[8];
            for (int i = 0; i < 8; i++) H[i] = SHA256_H0[i];
            uint* W = stackalloc uint[64];

            ulong totalBits = length * 8;
            ulong paddedLen = length + 1;
            while (paddedLen % 64 != 56) paddedLen++;
            paddedLen += 8;

            byte* block = stackalloc byte[64];
            ulong offset = 0;

            while (offset < paddedLen)
            {
                for (int i = 0; i < 64; i++) {
                    if (offset + (ulong)i < length) block[i] = data[offset + (ulong)i];
                    else if (offset + (ulong)i == length) block[i] = 0x80;
                    else block[i] = 0x00;
                }

                if (offset + 64 >= paddedLen) {
                    for (int i = 0; i < 8; i++) block[63 - i] = (byte)((totalBits >> (i * 8)) & 0xFF);
                }

                for (int t = 0; t < 16; t++) {
                    W[t] = ((uint)block[t * 4] << 24) | ((uint)block[t * 4 + 1] << 16) | ((uint)block[t * 4 + 2] << 8) | (uint)block[t * 4 + 3];
                }
                for (int t = 16; t < 64; t++) {
                    W[t] = SIG1(W[t - 2]) + W[t - 7] + SIG0(W[t - 15]) + W[t - 16];
                }

                uint a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];

                for (int t = 0; t < 64; t++) {
                    uint T1 = h + EP1(e) + CH(e, f, g) + Kptr[t] + W[t];
                    uint T2 = EP0(a) + MAJ(a, b, c);
                    h = g; g = f; f = e; e = d + T1;
                    d = c; c = b; b = a; a = T1 + T2;
                }

                H[0] += a; H[1] += b; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
                offset += 64;
            }

            for (int i = 0; i < 8; i++) {
                outputHash[i * 4] = (byte)((H[i] >> 24) & 0xFF);
                outputHash[i * 4 + 1] = (byte)((H[i] >> 16) & 0xFF);
                outputHash[i * 4 + 2] = (byte)((H[i] >> 8) & 0xFF);
                outputHash[i * 4 + 3] = (byte)(H[i] & 0xFF);
            }
        }
    }
}
