;
; This file contains fixes for this bullshit (compiler bug):
;
; Error: AggregateException_ctor_DefaultMessage (Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()')
; System.AggregateException: AggregateException_ctor_DefaultMessage (Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()')
; ---> ILCompiler.CodeGenerationFailedException: Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()'
; ---> System.InvalidOperationException: Expected method 'ThrowOverflowException' not found on type '[zerolib]Internal.Runtime.CompilerHelpers.ThrowHelpers'
;   at Internal.IL.HelperExtensions.GetKnownMethod(TypeDesc, String, MethodSignature) + 0x64
;   at ILCompiler.JitHelper.GetEntryPoint(TypeSystemContext, ReadyToRunHelper, String&, MethodDesc&) + 0x324
;   at ILCompiler.ILScanner.HelperCache.CreateValueFromKey(ReadyToRunHelper) + 0x40
;   at Internal.TypeSystem.LockFreeReaderHashtable`2.CreateValueAndEnsureValueIsInTable(TKey) + 0x14
;   at Internal.IL.ILImporter.ImportBinaryOperation(ILOpcode) + 0x727
;   at Internal.IL.ILImporter.ImportBasicBlock(ILImporter.BasicBlock) + 0x2a7
;   at Internal.IL.ILImporter.ImportBasicBlocks() + 0x59
;   at Internal.IL.ILImporter.Import() + 0x447
;   at ILCompiler.ILScanner.CompileSingleMethod(ScannedMethodNode) + 0x53
;   Exception_EndOfInnerExceptionStack
;   at ILCompiler.ILScanner.CompileSingleMethod(ScannedMethodNode) + 0x104
;   at System.Threading.Tasks.Parallel.<>c__DisplayClass19_0`2.<ForWorker>b__1(RangeWorker&, Int64, Boolean&) + 0x282
;--- End of stack trace from previous location ---
;   at System.Threading.Tasks.Parallel.<>c__DisplayClass19_0`2.<ForWorker>b__1(RangeWorker&, Int64, Boolean&) + 0x37f
;   at System.Threading.Tasks.TaskReplicator.Replica.Execute() + 0x65
;   Exception_EndOfInnerExceptionStack
;   at System.Threading.Tasks.TaskReplicator.Run[TState](TaskReplicator.ReplicatableUserAction`1, ParallelOptions, Boolean) + 0x155
;   at System.Threading.Tasks.Parallel.ForWorker[TLocal,TInt](TInt, TInt, ParallelOptions, Action`1, Action`2, Func`4, Func`1, Action`1) + 0x208
;--- End of stack trace from previous location ---
;   at System.Threading.Tasks.Parallel.ThrowSingleCancellationExceptionOrOtherException(ICollection, CancellationToken, Exception) + 0x31
;   at System.Threading.Tasks.Parallel.ForWorker[TLocal,TInt](TInt, TInt, ParallelOptions, Action`1, Action`2, Func`4, Func`1, Action`1) + 0x33c
;   at System.Threading.Tasks.Parallel.ForEachWorker[TSource,TLocal](IEnumerable`1, ParallelOptions, Action`1, Action`2, Action`3, Func`4, Func`5, Func`1, Action`1) + 0x112
;   at System.Threading.Tasks.Parallel.ForEach[TSource](IEnumerable`1, ParallelOptions, Action`1) + 0x49
;   at ILCompiler.ILScanner.CompileMultiThreaded(List`1) + 0x16a
;   at ILCompiler.ILScanner.ComputeDependencyNodeDependencies(List`1) + 0x164
;   at ILCompiler.DependencyAnalysisFramework.DependencyAnalyzer`2.ComputeMarkedNodes() + 0x9f
;   at ILCompiler.ILScanner.ILCompiler.IILScanner.Scan() + 0x565
;   at BuildCommand.Handle(ParseResult) + 0x2a64
;   at System.CommandLine.Invocation.InvocationPipeline.<>c__DisplayClass4_0.<<BuildInvocationChain>b__0>d.MoveNext() + 0xdb
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass17_0.<<UseParseErrorReporting>b__0>d.MoveNext() + 0x58
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass12_0.<<UseHelp>b__0>d.MoveNext() + 0x51
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass23_0.<<UseVersionOption>b__0>d.MoveNext() + 0x59
;--- End of stack trace from previous location ---
;   at System.CommandLine.Invocation.InvocationPipeline.<Invoke>g__FullInvocationChain|3_0(InvocationContext) + 0x86
;   at Program.Main(String[] args) + 0x227
;
; You can see? bflat constantly complains about the lack of overflow exception handling. 
; This damn thing has been tormenting us right from the kernel writing stage!
;
; To shut this stubbornly conservative compiler up forever, we need force. 
; Writing assembly code is the most powerful thing we can do.
;
; Damn bflat, I'm going to switch this entire operating system to Pascal
; or something else soon. 
;
; Fuck bflat! Damn it, this goddamn compiler hasn't been updated in ages...
;

bits 64
section .text
global xorshift32
align 16
xorshift32:
    mov eax, ecx

    ; v ^= v << 13;
    mov edx, eax
    shl edx, 13
    xor eax, edx

    ; v ^= v >> 17;
    mov edx, eax
    shr edx, 17
    xor eax, edx

    ; v ^= v << 5;
    mov edx, eax
    shl edx, 5
    xor eax, edx

    ret