# Spec Delta

## Purpose

This capability classifies telemetry into explicitly selected routing streams and applies audience-specific destination policies while preserving each stream through delivery.

## ADDED Requirements

### Requirement: Trace routes are explicit and independent of destinations

A gateway SHALL route a trace only according to an explicit route selection at a declared ingress or producer/export stream boundary. The presence of a specialized destination or arbitrary span/resource attributes SHALL NOT classify telemetry. A producer or relay MAY select a route with a dedicated, documented routing field or endpoint; route selection SHALL NOT be inferred from descriptive telemetry content.

#### Scenario: General telemetry with specialized backends configured

- **WHEN** a gateway has general and AI-specialized destinations configured, and receives a trace on the general route
- **THEN** it forwards that trace only to the general route's destinations and does not forward it to AI-specialized destinations, even if descriptive span attributes resemble AI telemetry

#### Scenario: Explicit AI-session stream

- **WHEN** a producer or relay explicitly selects the AI-session route through its declared stream binding
- **THEN** the gateway applies the AI-session route's configured destination policy to that trace stream

### Requirement: Route policy controls destination fan-out

Each named trace route SHALL have an explicit destination set. A route MAY select both general and specialized destinations; configuring one route SHALL NOT implicitly add its destinations to another route.

#### Scenario: AI session also retained in general store

- **WHEN** the AI-session route explicitly selects both the general store and AI-specialized backends
- **THEN** the full AI-session stream is offered to each selected destination

#### Scenario: No implicit shared destination

- **WHEN** a specialized route selects AI backends but omits the general store
- **THEN** that route is not silently copied to the general store

### Requirement: Route identity is preserved through processing and delivery

Routing classification SHALL remain attached to telemetry through receiver processing, batching, queueing, retry, and fan-out. A batch or retry operation SHALL NOT combine records from different routes in a way that delivers a record to a destination not selected for its route.

#### Scenario: Mixed general and AI traffic

- **WHEN** general traces and AI-session traces are received close together and are eligible for batching
- **THEN** each record is delivered only to destinations selected by its own route

#### Scenario: Partial fan-out retry

- **WHEN** one destination fails while another accepts a batch for an AI-session route
- **THEN** retry behavior remains scoped to that route and destination and does not replay general-route traces to the AI backend

### Requirement: Existing producers remain on the general route by default

A producer that does not select a specialized route SHALL continue to use the existing general trace-routing behavior. Introducing specialized routes SHALL NOT require unrelated producers to change their OTLP protocol or producer interface.

#### Scenario: Unchanged infrastructure producer

- **WHEN** an existing infrastructure or application producer continues sending traces without selecting an AI-session route
- **THEN** its traces continue to the explicitly configured general destinations and no AI-specific declaration is required

### Requirement: Route selection is routing, not authorization

The route contract SHALL describe routing classification and destination policy only. It SHALL NOT claim that route selection authenticates or authorizes a producer.

#### Scenario: Route declaration without authorization semantics

- **WHEN** a producer or consumer selects a named route
- **THEN** the system treats that declaration as routing input and makes no authentication or access-control guarantee
