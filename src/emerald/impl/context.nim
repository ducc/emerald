import sets, tagdef, tables, strutils, macros
import writer

type
    OutputMode* = enum
        unknown, blockmode, flowmode
    
    ParseContext* = ref ContextObj not nil
    
    MixinLevelObj = object
        callbackContent: NimNode
        callable: bool
        callbackWriter: StmtListWriter
        callContentSyms: seq[tuple[varSym: NimNode, paramSym: NimNode]]
    
    MixinLevel* = ref MixinLevelObj not nil

    ContextLevel = object
        outputMode: OutputMode
        forbiddenCategories: set[ContentCategory]
        forbiddenTags: set[TagId]
        permitted_content: set[ContentCategory]
        permittedTags: set[TagId]
        indentLength: int
        indentStep: int
        compactOutput: bool
        filters: seq[NimNode]

    ContextObj = object
        globalStmtList: NimNode
        level: int
        levelProps: seq[ContextLevel]
        mixinLevels: seq[MixinLevel]
    

template curLevel(): auto {.dirty.} = context.levelProps[context.level]

proc mode*(context: ParseContext): OutputMode {.inline, noSideEffect,
                                                compileTime.} =
    if curLevel.compactOutput: flowmode else: curLevel.outputMode

proc `mode=`*(context: ParseContext, val: OutputMode) {.inline, compileTime.} =
    curLevel.outputMode = val

proc newMixinLevel*(callbackContent: NimNode): MixinLevel {.compileTime.} =
    new(result)
    result.callbackContent = callbackContent
    result.callable = false

proc newMixinLevel*(callbackContent: NimNode, writer: StmtListWriter):
        MixinLevel {.compileTime.} =
    new(result)
    result.callbackContent = callbackContent
    result.callable = true
    result.callbackWriter = writer
    result.callContentSyms = newSeq[tuple[varSym: NimNode, paramSym: NimNode]]()

proc callback_content*(ml: MixinLevel): NimNode {.compileTime.} =
    ml.callbackContent

proc add_call*(ml: MixinLevel):
        tuple[varSym: NimNode, paramSym: NimNode] {.compileTime.} =
    result = (varSym : genSym(nskVar, ":m" & $(ml.callContentSyms.len)),
            paramSym: genSym(nskParam, ":content" &
            $(ml.callContentSyms.len)))
    ml.callContentSyms.add(result)

iterator call_content_syms*(ml: MixinLevel):
        tuple[varSym: NimNode, paramSym: NimNode] =
    for sym in ml.callContentSyms:
        yield sym

proc writer*(ml: MixinLevel): StmtListWriter {.compileTime.} = ml.callbackWriter

proc calls_content*(ml: MixinLevel): NimNode {.compileTime.} =
    ml.callbackWriter.result

proc num_calls*(ml: MixinLevel): int {.compileTime.} = ml.callContentSyms.len 

proc callable*(ml: MixinLevel): bool = ml.callable

proc newContext*(globalStmtList: NimNode,
                 primaryTagId : ExtendedTagId = unknownTag,
                 mode: OutputMode = unknown): ParseContext {.compileTime.} =
    new(result)
    result.globalStmtList = globalStmtList
    result.level = 0
    result.mixinLevels = newSeq[MixinLevel]()
    result.levelProps = @[ContextLevel(
            outputMode : mode,
            forbiddenCategories : set[ContentCategory]({}),
            forbiddenTags : set[TagId]({}),
            permitted_content : set[ContentCategory]({}),
            permittedTags : set[TagId]({}),
            indentLength : 0,
            indentStep : 4,
            compactOutput: false,
            filters: newSeq[NimNode]()
        )]
    if primaryTagId == low(TagId) - 1:
        result.levelProps[0].permitted_content.incl(any_content)
    else:
        result.levelProps[0].permittedTags.incl(TagId(primaryTagId))

proc copy*(context: ParseContext): ParseContext {.compileTime.} =
    new(result)
    result.globalStmtList = copyNimTree(context.globalStmtList)
    result.level = context.level
    result.mixinLevels = context.mixinLevels
    result.levelProps = context.levelProps

proc depth*(context: ParseContext): int {.inline, compileTime.} =
    return context.level - 1

proc enter*(context: ParseContext, tag: TagDef) {.compileTime.} =
    # SIGSEGV! (probably a compiler bug; works at runtime, but not at compiletime)
    #forbiddenTags : context.forbiddenTags + tag.forbiddenTags
    context.levelProps.add(ContextLevel(
            outputMode : if context.mode == flowmode: flowmode else: unknown,
            forbiddenCategories : curLevel.forbiddenCategories,
            forbiddenTags : curLevel.forbiddenTags,
            permittedContent: if tag.permittedContent.contains(transparent):
                curLevel.permitted_content
                else: tag.permitted_content,
            permittedTags : if tag.permitted_content.contains(transparent):
                curLevel.permittedTags
                else: tag.permittedTags,
            indentLength : curLevel.indentLength + curLevel.indentStep,
            indentStep : curLevel.indentStep,
            compactOutput : curLevel.compactOutput,
            filters : curLevel.filters
        ))
    inc(context.level)

    for i in tag.forbiddenTags:
        curLevel.forbiddenTags.incl(i)
    for i in tag.forbiddenContent: 
        curLevel.forbiddenCategories.incl(i)

proc exit*(context: ParseContext) {.compileTime.} =
    assert context.level > 0
    discard context.levelProps.pop()
    inc(context.level, -1)

proc accepts*(context: ParseContext, tag: TagDef): bool {.compileTime.} =
    result = false
    if curLevel.permitted_content.contains(any_content):
        return true
    if curLevel.forbiddenTags.contains(tag.id): return false
    if curLevel.permittedTags.contains(tag.id):
        result = true
    for category in tag.contentCategories:
        if curLevel.forbiddenCategories.contains(category):
            return false
        if curLevel.permitted_content.contains(category):
            result = true

proc indentation*(context: ParseContext): string {.compileTime.} =
     repeat(' ', curLevel.indentLength)

proc `indent_step=`*(context: ParseContext, val: int) {.compileTime.} =
    curLevel.indentStep = val

proc compact_output*(context: ParseContext): bool {.compileTime.} =
    context.compactOutput

proc `compact_output=`*(context: ParseContext, val: bool) {.compileTime.} =
    curLevel.compactOutput = val

proc filters*(context: ParseContext): seq[NimNode] {.compileTime.} =
    curLevel.filters

proc `filters=`*(context: ParseContext, val: seq[NimNode]) {.compileTime.} =
    curLevel.filters = val

proc global_stmt_list*(context: ParseContext): NimNode {.compileTime.} =
    context.globalStmtList

proc push_mixin_level*(context: ParseContext, lev: MixinLevel) {.compileTime.} =
    context.mixinLevels.add(lev)

proc mixin_level*(context: ParseContext): MixinLevel {.compileTime.} =
    context.mixinLevels[context.mixinLevels.len - 1]

proc pop_mixin_level*(context: ParseContext): MixinLevel {.compileTime.} =
    context.mixinLevels.pop()
