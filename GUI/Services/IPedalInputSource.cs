using PedDash.Models;
using System;
using System.Threading;

namespace PedDash.Services
{
    public interface IPedalInputSource : IDisposable
    {
        string DisplayName { get; }

        InputReadResult Read(CancellationToken cancellationToken);
    }
}
