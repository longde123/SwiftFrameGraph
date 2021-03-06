//
//  ArgumentEncoder.swift
//  RenderAPI
//
//  Created by Thomas Roughton on 22/02/18.
//

import Foundation
import Utilities

public protocol FunctionArgumentKey {
    var stringValue : String { get }
    func bindingPath(arrayIndex: Int, argumentBufferPath: ResourceBindingPath?) -> ResourceBindingPath?
}

extension RawRepresentable where Self.RawValue == String {
    public var stringValue : String {
        return self.rawValue
    }
}

@_fixed_layout
public struct FunctionArgumentCodingKey : FunctionArgumentKey {
    public let codingKey : CodingKey
    
    @inlinable
    public init(_ codingKey: CodingKey) {
        self.codingKey = codingKey
    }
    
    @inlinable
    public var stringValue: String {
        return self.codingKey.stringValue
    }
}

extension FunctionArgumentKey {
    
    @inlinable
    public func bindingPath(arrayIndex: Int, argumentBufferPath: ResourceBindingPath?) -> ResourceBindingPath? {
        return nil
    }
    
    @inlinable
    public func bindingPath(argumentBufferPath: ResourceBindingPath?, arrayIndex: Int, pipelineReflection: PipelineReflection) -> ResourceBindingPath? {
        return self.bindingPath(arrayIndex: arrayIndex, argumentBufferPath: argumentBufferPath) ?? pipelineReflection.bindingPath(argumentName: self.stringValue, arrayIndex: arrayIndex, argumentBufferPath: argumentBufferPath)
    }
    
    @inlinable
    public func computedBindingPath(pipelineReflection: PipelineReflection) -> ResourceBindingPath? {
        return self.bindingPath(arrayIndex: 0, argumentBufferPath: nil) ?? pipelineReflection.bindingPath(argumentName: self.stringValue, arrayIndex: 0, argumentBufferPath: nil)
    }
}

extension String : FunctionArgumentKey {
    @inlinable
    public var stringValue : String {
        return self
    }
}

@_fixed_layout
public struct _ArgumentBufferData {
    public fileprivate(set) var enqueuedBindings = ExpandingBuffer<(FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource)>()
    public var bindings = [(ResourceBindingPath, _ArgumentBuffer.ArgumentResource)]()
    
    public init() {
        
    }
    
    public mutating func translateEnqueuedBindings(_ closure: (FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource) -> ResourceBindingPath?) {
        let unhandledBindings = ExpandingBuffer<(FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource)>()
        
        while let (key, arrayIndex, binding) = self.enqueuedBindings.popLast() {
            if let bindingPath = closure(key, arrayIndex, binding) {
                self.bindings.append((bindingPath, binding))
            } else {
                unhandledBindings.append((key, arrayIndex, binding))
            }
        }
        
        self.enqueuedBindings = unhandledBindings
    }
}


@_fixed_layout
public struct _ArgumentBuffer : ResourceProtocol {
    
    public let handle : Handle
    
    public enum ArgumentResource {
        case buffer(Buffer, offset: Int)
        case texture(Texture)
        case sampler(SamplerDescriptor)
        // Where offset is the source offset in the source Data.
        case bytes(offset: Int, length: Int)
    }
    
    @inlinable
    public init(existingHandle: Handle) {
        self.handle = existingHandle
    }
    
    @inlinable
    init(flags: ResourceFlags = []) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentArgumentBufferRegistry.instance.allocate(flags: flags)
        } else {
            index = TransientArgumentBufferRegistry.instance.allocate(flags: flags)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.argumentBuffer.rawValue) << 48)
    }
    
    @inlinable
    init(flags: ResourceFlags = [], sourceArray: _ArgumentBufferArray) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentArgumentBufferRegistry.instance.allocate(flags: flags, sourceArray: sourceArray)
        } else {
            index = TransientArgumentBufferRegistry.instance.allocate(flags: flags, sourceArray: sourceArray)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.argumentBuffer.rawValue) << 48)
    }
    
    @inlinable
    public var sourceArray : _ArgumentBufferArray? {
        if self.flags.contains(.resourceView) {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferRegistry.instance.sourceArrays[self.index]
            } else {
                return TransientArgumentBufferRegistry.instance.sourceArrays[self.index]
            }
        }
        return nil
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return []
        }
        nonmutating set {
        }
    }
    
    @inlinable
    public var enqueuedBindings : ExpandingBuffer<(FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource)> {
        get {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferRegistry.instance.data[self.index].enqueuedBindings
            } else {
                return TransientArgumentBufferRegistry.instance.data[self.index].enqueuedBindings
            }
        }
    }
    
    @inlinable
    public var bindings : [(ResourceBindingPath, _ArgumentBuffer.ArgumentResource)] {
        get {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferRegistry.instance.data[self.index].bindings
            } else {
                return TransientArgumentBufferRegistry.instance.data[self.index].bindings
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                PersistentArgumentBufferRegistry.instance.data[self.index].bindings = newValue
            } else {
                TransientArgumentBufferRegistry.instance.data[self.index].bindings = newValue
            }
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferRegistry.instance.labels[self.index]
            } else {
                return TransientArgumentBufferRegistry.instance.labels[self.index]
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                PersistentArgumentBufferRegistry.instance.labels[self.index] = newValue
            } else {
                TransientArgumentBufferRegistry.instance.labels[self.index] = newValue
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return .shared
    }
    
    // Thread-safe
    public func translateEnqueuedBindings(_ closure: (FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource) -> ResourceBindingPath?) {
        if self._usesPersistentRegistry {
            PersistentArgumentBufferRegistry.instance.queue.sync { PersistentArgumentBufferRegistry.instance.data[self.index].translateEnqueuedBindings(closure)
            }
        } else {
            TransientArgumentBufferRegistry.instance.queue.sync {
                TransientArgumentBufferRegistry.instance.data[self.index].translateEnqueuedBindings(closure)
                
            }
        }
    }
    
    @inlinable
    public func _bytes(offset: Int) -> UnsafeRawPointer {
        if self._usesPersistentRegistry {
            return PersistentArgumentBufferRegistry.instance.inlineDataStorage[self.index].withUnsafeBytes { return UnsafeRawPointer($0) + offset }
        } else {
            return UnsafeRawPointer(TransientArgumentBufferRegistry.instance.inlineDataAllocator.buffer) + offset
        }
    }
    
    /// returns the offset in bytes into the buffer's storage
    @inlinable
    public func _copyBytes(_ bytes: UnsafeRawPointer, length: Int) -> Int {
        if self._usesPersistentRegistry {
            return PersistentArgumentBufferRegistry.instance.queue.sync {
                let offset = PersistentArgumentBufferRegistry.instance.inlineDataStorage[self.index].count
                PersistentArgumentBufferRegistry.instance.inlineDataStorage[self.index].append(bytes.assumingMemoryBound(to: UInt8.self), count: length)
                return offset
            }
        } else {
            return TransientArgumentBufferRegistry.instance.queue.sync {
                let offset = TransientArgumentBufferRegistry.instance.inlineDataAllocator.count
                TransientArgumentBufferRegistry.instance.inlineDataAllocator.append(from: bytes.assumingMemoryBound(to: UInt8.self), count: length)
                return offset
            }
        }
    }
    
    @inlinable
    public func dispose() {
        guard self._usesPersistentRegistry else {
            return
        }
        PersistentArgumentBufferRegistry.instance.dispose(self)
    }
}

@_fixed_layout
public struct _ArgumentBufferArray : ResourceProtocol {
    public let handle : Handle
    
    @inlinable
    public init(existingHandle: Handle) {
        self.handle = existingHandle
    }
    
    @inlinable
    init(flags: ResourceFlags = []) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentArgumentBufferArrayRegistry.instance.allocate(flags: flags)
        } else {
            index = TransientArgumentBufferArrayRegistry.instance.allocate(flags: flags)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.argumentBufferArray.rawValue) << 48)
    }
    
    @inlinable
    public func dispose() {
        guard self._usesPersistentRegistry else {
            return
        }
        for binding in self._bindings {
            binding?.dispose()
        }
        PersistentArgumentBufferArrayRegistry.instance.dispose(self)
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return []
        }
        nonmutating set {
        }
    }
    
    @inlinable
    public var _bindings : [_ArgumentBuffer?] {
        get {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferArrayRegistry.instance.bindings[self.index]
            } else {
                return TransientArgumentBufferArrayRegistry.instance.bindings[self.index]
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                PersistentArgumentBufferArrayRegistry.instance.bindings[self.index] = newValue
            } else {
                TransientArgumentBufferArrayRegistry.instance.bindings[self.index] = newValue
            }
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            if self._usesPersistentRegistry {
                return PersistentArgumentBufferArrayRegistry.instance.labels[self.index]
            } else {
                return TransientArgumentBufferArrayRegistry.instance.labels[self.index]
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                PersistentArgumentBufferArrayRegistry.instance.labels[self.index] = newValue
            } else {
                TransientArgumentBufferArrayRegistry.instance.labels[self.index] = newValue
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return .shared
    }
}

@_fixed_layout
public struct ArgumentBuffer<K : FunctionArgumentKey> : ResourceProtocol {
    
    public let argumentBuffer : _ArgumentBuffer
    
    @inlinable
    public init(existingHandle: Handle) {
        self.argumentBuffer = _ArgumentBuffer(existingHandle: existingHandle)
    }
    
    @inlinable
    public init(flags: ResourceFlags) {
        self.argumentBuffer = _ArgumentBuffer(flags: flags)
    }
    
    @inlinable
    public func dispose() {
        self.argumentBuffer.dispose()
    }
    
    @inlinable
    public var handle: Resource.Handle {
        return self.argumentBuffer.handle
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return self.argumentBuffer.stateFlags
        }
        nonmutating set {
            self.argumentBuffer.stateFlags = newValue
        }
    }
    
    @inlinable
    public var flags : ResourceFlags {
        return self.argumentBuffer.flags
    }
    
    @inlinable
    public var sourceArray : ArgumentBufferArray<K>? {
        return self.argumentBuffer.sourceArray.map { ArgumentBufferArray(existingHandle: $0.handle) }
    }
    
    @inlinable
    public var _enqueuedBindings : ExpandingBuffer<(FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource)> {
        return self.argumentBuffer.enqueuedBindings
    }
    
    @inlinable
    public func setBuffer(_ buffer: Buffer?, offset: Int, key: K, arrayIndex: Int = 0) {
        guard let buffer = buffer else { return }
        
        assert(!self.flags.contains(.persistent) || buffer.flags.contains(.persistent), "A persistent argument buffer can only contain persistent resources.")
        self._enqueuedBindings.append(
            (key, arrayIndex, .buffer(buffer, offset: offset))
        )
    }
    
    @inlinable
    public func setTexture(_ texture: Texture, key: K, arrayIndex: Int = 0) {
        assert(!self.flags.contains(.persistent) || texture.flags.contains(.persistent), "A persistent argument buffer can only contain persistent resources.")
        self._enqueuedBindings.append(
            (key, arrayIndex, .texture(texture))
        )
    }
    
    @inlinable
    public func setSampler(_ sampler: SamplerDescriptor, key: K, arrayIndex: Int = 0) {
        self._enqueuedBindings.append(
            (key, arrayIndex, .sampler(sampler))
        )
    }
    
    @inlinable
    public func setValue<T>(_ value: T, key: K, arrayIndex: Int = 0) {
        var value = value
        withUnsafeBytes(of: &value) { bufferPointer in
            self.setBytes(bufferPointer.baseAddress!, length: bufferPointer.count, for: key, arrayIndex: arrayIndex)
        }
    }
    
    @inlinable
    public func setValue<T : ResourceProtocol>(_ value: T, key: FunctionArgumentKey, arrayIndex: Int = 0) {
        preconditionFailure("setValue should not be used with resources; use setBuffer or setTexture instead.")
    }
    
    @inlinable
    public func setBytes(_ bytes: UnsafeRawPointer, length: Int, for key: K, arrayIndex: Int = 0) {
        let currentOffset = self.argumentBuffer._copyBytes(bytes, length: length)
        self._enqueuedBindings.append(
            (key, arrayIndex, .bytes(offset: currentOffset, length: length))
        )
    }
}

extension ArgumentBuffer {
    
    public func setBuffers(_ buffers: [Buffer], offsets: [Int], keys: [K]) {
        for (buffer, (offset, key)) in zip(buffers, zip(offsets, keys)) {
            self.setBuffer(buffer, offset: offset, key: key)
        }
    }
    
    public func setTextures(_ textures: [Texture], keys: [K]) {
        for (texture, key) in zip(textures, keys) {
            self.setTexture(texture, key: key)
        }
    }
    
    public func setSamplers(_ samplers: [SamplerDescriptor], keys: [K]) {
        for (sampler, key) in zip(samplers, keys) {
            self.setSampler(sampler, key: key)
        }
    }
}

@_fixed_layout
public struct ArgumentBufferArray<K : FunctionArgumentKey> : ResourceProtocol {
    public let argumentBufferArray : _ArgumentBufferArray
    
    @inlinable
    public init(existingHandle: Handle) {
        self.argumentBufferArray = _ArgumentBufferArray(existingHandle: existingHandle)
    }
    
    @inlinable
    public init(flags: ResourceFlags = []) {
        self.argumentBufferArray = _ArgumentBufferArray(flags: flags)
    }
    
    @inlinable
    public func dispose() {
        self.argumentBufferArray.dispose()
    }
    
    @inlinable
    public var handle: _ArgumentBufferArray.Handle {
        return self.argumentBufferArray.handle
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return self.argumentBufferArray.stateFlags
        }
        nonmutating set {
            self.argumentBufferArray.stateFlags = newValue
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            return self.argumentBufferArray.label
        }
        nonmutating set {
            self.argumentBufferArray.label = newValue
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return self.argumentBufferArray.storageMode
    }
    
    public func reserveCapacity(_ capacity: Int) {
        self.argumentBufferArray._bindings.reserveCapacity(capacity)
    }
    
    public subscript(index: Int) -> ArgumentBuffer<K> {
        get {
            if index >= self.argumentBufferArray._bindings.count {
                self.argumentBufferArray._bindings.append(contentsOf: repeatElement(nil, count: index - self.argumentBufferArray._bindings.count + 1))
            }
            
            if let buffer = self.argumentBufferArray._bindings[index] {
                return ArgumentBuffer(existingHandle: buffer.handle)
            }
            
            let buffer = _ArgumentBuffer(flags: [self.flags, .resourceView], sourceArray: self.argumentBufferArray)
            self.argumentBufferArray._bindings[index] = buffer
            return ArgumentBuffer(existingHandle: buffer.handle)
        }
    }
}
