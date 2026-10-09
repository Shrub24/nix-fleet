# Spec Delta

## MODIFIED Requirements

### Requirement: Route policy controls destination fan-out

Each named trace route SHALL have an explicit destination set. A route MAY select both general and specialized destinations; configuring one route SHALL NOT implicitly add its destinations to another route. Destinations MAY receive explicitly configured payload views of the full received stream that preserve its span structure. With native Collector pipeline overrides, rendered pipelines SHALL determine effective routing; the route declaration SHALL determine the generated exporter and credential set, and the supported view composition SHALL assign each selected destination to exactly one effective output path.

#### Scenario: AI session also retained in general store

- **WHEN** the AI-session route explicitly selects both the general store and AI-specialized backends
- **THEN** the full received AI-session stream is offered to each selected destination, optionally with a lean content profile for the general store and rich profiles for the AI backends

#### Scenario: No implicit shared destination

- **WHEN** a specialized route selects AI backends but omits the general store
- **THEN** that route is not silently copied to the general store

#### Scenario: Native output-view composition

- **WHEN** a consumer overrides a generated route pipeline and adds sibling pipelines for different payload views
- **THEN** effective rendered assignments preserve the selected destination set without duplicate output paths, and the route declaration alone is not treated as proof of delivery
