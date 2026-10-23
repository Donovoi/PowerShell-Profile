using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace PowerShellProfile.Analysis {
    public sealed class EvidenceBudget {
        internal readonly object Gate = new object();
        internal long Remaining;
        public EvidenceBudget(long limit) { Remaining = limit; }
    }
    public sealed class BoundedEvidenceStream : Stream {
        readonly Stream output;
        readonly EvidenceBudget budget;
        public BoundedEvidenceStream(Stream output, EvidenceBudget budget) { this.output = output; this.budget = budget; }
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => output.Length;
        public override long Position { get => output.Position; set => throw new NotSupportedException(); }
        public override void Flush() => output.Flush();
        public override int Read(byte[] b, int o, int c) => throw new NotSupportedException();
        public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long n) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) {
            lock (budget.Gate) {
                int retained = (int)Math.Min(count, budget.Remaining);
                if (retained > 0) { output.Write(buffer, offset, retained); budget.Remaining -= retained; }
                if (retained < count) throw new IOException("Evidence output byte budget exceeded.");
            }
        }
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken token) {
            try { token.ThrowIfCancellationRequested(); Write(buffer, offset, count); return Task.CompletedTask; }
            catch (Exception error) { return Task.FromException(error); }
        }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default) {
            return new ValueTask(WriteAsync(buffer.ToArray(), 0, buffer.Length, token));
        }
    }
}
