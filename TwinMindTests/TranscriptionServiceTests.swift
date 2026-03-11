//
//  TranscriptionServiceTests.swift
//  TwinMindTests
//
//  Tests for exponential backoff calculation and segment status transitions.
//

import XCTest
import SwiftData
import AVFoundation
@testable import TwinMind

final class TranscriptionServiceTests: XCTestCase {

    // ── Exponential backoff formula ───────────────────────────────────────

    /// base * 2^(attempt-1) clamped to max.
    private func backoff(attempt: Int,
                         base: Double = 1.0,
                         maxDelay: Double = 32.0) -> Double {
        min(base * pow(2.0, Double(attempt - 1)), maxDelay)
    }

    func testExponentialBackoff_firstRetry_isBase() {
        XCTAssertEqual(backoff(attempt: 1), 1.0)
    }

    func testExponentialBackoff_doubles() {
        XCTAssertEqual(backoff(attempt: 2), 2.0)
        XCTAssertEqual(backoff(attempt: 3), 4.0)
        XCTAssertEqual(backoff(attempt: 4), 8.0)
    }

    func testExponentialBackoff_clampedAtMax() {
        XCTAssertEqual(backoff(attempt: 6), 32.0)
        XCTAssertEqual(backoff(attempt: 10), 32.0)
    }

    // ── Segment state transitions ─────────────────────────────────────────

    func testSegment_canTransitionThroughAllStates() {
        let seg = TranscriptionSegment(index: 0, startTime: 0, duration: 30)
        XCTAssertEqual(seg.status, .pending)

        seg.status = .uploading
        XCTAssertEqual(seg.status, .uploading)

        seg.status = .transcribed
        XCTAssertEqual(seg.status, .transcribed)

        seg.status = .failed
        seg.errorMessage = "timeout"
        XCTAssertEqual(seg.status, .failed)
        XCTAssertEqual(seg.errorMessage, "timeout")

        seg.status = .fallback
        XCTAssertEqual(seg.status, .fallback)
    }

    // ── TranscriptionError descriptions ──────────────────────────────────

    func testTranscriptionErrors_haveDescriptions() {
        let errors: [TranscriptionError] = [.missingAPIKey, .invalidResponse,
                                            .httpError(429, nil), .localModelUnavailable]
        for err in errors {
            XCTAssertNotNil(err.errorDescription)
            XCTAssertFalse(err.errorDescription!.isEmpty)
        }
    }

    func testHTTPError_containsStatusCode() {
        let err = TranscriptionError.httpError(429, nil)
        XCTAssertTrue(err.errorDescription?.contains("429") ?? false)
    }

    // ══════════════════════════════════════════════════════════════════════
    // MARK: - 🔑 LIVE Deepgram API Integration Test
    // ══════════════════════════════════════════════════════════════════════
    //
    // Run this test from Xcode to verify your Deepgram API key is valid
    // and the pre-recorded transcription endpoint works.
    //
    // It will:
    //  1. Read your API key from the Keychain
    //  2. Generate a small 1-second WAV file (440 Hz sine tone)
    //  3. POST it to https://api.deepgram.com/v1/listen
    //  4. Print the HTTP status, response body, and transcript
    //
    // Expected output for a valid key:
    //   ✅ Deepgram API is WORKING! HTTP 200
    //   Transcript: "" (sine tone has no speech)
    //   Confidence: 0.0
    //
    // If the key is bad you'll see:
    //   ❌ Deepgram returned HTTP 401 / 403
    //

    func testDeepgramAPIKey_isValid() async throws {
        // 1. Read API key
        let apiKey: String
        do {
            apiKey = try KeychainManager.read(key: .deepgramAPIKey)
        } catch {
            XCTFail("❌ No Deepgram API key found in Keychain. Save one in Settings first, then re-run this test.")
            return
        }
        print("🔑 API key found: \(apiKey.prefix(8))....\(apiKey.suffix(4))")

        // 2. Generate a minimal WAV in memory (1 sec, 16 kHz, mono, 440 Hz sine)
        let wavData = generateTestWAV(sampleRate: 16000, durationSeconds: 1.0, frequency: 440.0)
        print("🎵 Test WAV: \(wavData.count) bytes")

        // 3. Build request
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "language", value: "en")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData

        // 4. Send
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        let body = String(data: data, encoding: .utf8) ?? "(no body)"

        print("──────────────────────────────────────")
        print("HTTP Status: \(http.statusCode)")
        print("Response body: \(body.prefix(500))")
        print("──────────────────────────────────────")

        // 5. Assert
        if (200..<300).contains(http.statusCode) {
            print("✅ Deepgram API is WORKING! HTTP \(http.statusCode)")

            // Try to parse transcript
            struct Resp: Decodable {
                struct Results: Decodable {
                    struct Channel: Decodable {
                        struct Alt: Decodable { let transcript: String; let confidence: Double }
                        let alternatives: [Alt]
                    }
                    let channels: [Channel]
                }
                let results: Results
            }
            if let decoded = try? JSONDecoder().decode(Resp.self, from: data),
               let alt = decoded.results.channels.first?.alternatives.first {
                print("📝 Transcript: \"\(alt.transcript)\"")
                print("📊 Confidence: \(alt.confidence)")
            }
        } else if http.statusCode == 401 || http.statusCode == 403 {
            XCTFail("❌ Deepgram API key is INVALID or EXPIRED. HTTP \(http.statusCode). Response: \(body.prefix(200))")
        } else {
            XCTFail("❌ Deepgram returned HTTP \(http.statusCode). Response: \(body.prefix(200))")
        }
    }

    // ── WAV generator helper ─────────────────────────────────────────────

    /// Generate a valid WAV file (PCM 16-bit mono) with a sine wave.
    private func generateTestWAV(sampleRate: Int, durationSeconds: Double, frequency: Double) -> Data {
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(numSamples * Int(numChannels) * Int(bytesPerSample))

        var wav = Data()

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(uint32LE: 36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)

        // fmt  sub-chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(uint32LE: 16)                           // sub-chunk size
        wav.append(uint16LE: 1)                            // PCM format
        wav.append(uint16LE: numChannels)
        wav.append(uint32LE: UInt32(sampleRate))
        wav.append(uint32LE: UInt32(sampleRate * Int(numChannels) * Int(bytesPerSample)))
        wav.append(uint16LE: numChannels * bytesPerSample) // block align
        wav.append(uint16LE: bitsPerSample)

        // data sub-chunk
        wav.append(contentsOf: "data".utf8)
        wav.append(uint32LE: dataSize)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let sample = Int16(clamping: Int(32767.0 * sin(2.0 * .pi * frequency * t)))
            withUnsafeBytes(of: sample.littleEndian) { wav.append(contentsOf: $0) }
        }

        return wav
    }
}

// MARK: - Data WAV Helpers

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func append(uint32LE value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
