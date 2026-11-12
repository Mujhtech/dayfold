use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Deserializer, de};
use serde_json::{Map, Number, Value};
use std::fmt;

/// Reject duplicate members recursively before interpreting security claims.
/// `serde_json::Value` normally keeps the last duplicate member silently.
struct UniqueValue(Value);

impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> de::Visitor<'de> for Visitor {
            type Value = UniqueValue;
            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("JSON with unique object members")
            }
            fn visit_bool<E: de::Error>(self, value: bool) -> Result<Self::Value, E> {
                Ok(UniqueValue(Value::Bool(value)))
            }
            fn visit_i64<E: de::Error>(self, value: i64) -> Result<Self::Value, E> {
                Ok(UniqueValue(Value::Number(value.into())))
            }
            fn visit_u64<E: de::Error>(self, value: u64) -> Result<Self::Value, E> {
                Ok(UniqueValue(Value::Number(value.into())))
            }
            fn visit_f64<E: de::Error>(self, value: f64) -> Result<Self::Value, E> {
                Number::from_f64(value)
                    .map(|number| UniqueValue(Value::Number(number)))
                    .ok_or_else(|| E::custom("invalid number"))
            }
            fn visit_str<E: de::Error>(self, value: &str) -> Result<Self::Value, E> {
                Ok(UniqueValue(Value::String(value.into())))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
                Ok(UniqueValue(Value::Null))
            }
            fn visit_seq<A: de::SeqAccess<'de>>(
                self,
                mut sequence: A,
            ) -> Result<Self::Value, A::Error> {
                let mut values = Vec::new();
                while let Some(UniqueValue(value)) = sequence.next_element()? {
                    values.push(value);
                }
                Ok(UniqueValue(Value::Array(values)))
            }
            fn visit_map<A: de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut values = Map::new();
                while let Some((key, UniqueValue(value))) =
                    map.next_entry::<String, UniqueValue>()?
                {
                    if values.insert(key, value).is_some() {
                        return Err(de::Error::custom("duplicate member"));
                    }
                }
                Ok(UniqueValue(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}

pub(crate) fn parse(bytes: &[u8]) -> Result<Value, ()> {
    serde_json::from_slice::<UniqueValue>(bytes)
        .map(|value| value.0)
        .map_err(|_| ())
}

pub(crate) fn decode_canonical(value: &str) -> Result<Vec<u8>, ()> {
    let bytes = URL_SAFE_NO_PAD.decode(value).map_err(|_| ())?;
    if URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(());
    }
    Ok(bytes)
}

/// Bound all untrusted JWT parsing; require compact JWS with three segments.
pub(crate) fn token_parts(token: &str) -> Result<(Value, Value), ()> {
    if token.is_empty() || token.len() > 16_384 || !token.is_ascii() {
        return Err(());
    }
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|part| part.is_empty()) || parts[0].len() > 4096 {
        return Err(());
    }
    let signature = decode_canonical(parts[2])?;
    if signature.len() > 1024 {
        return Err(());
    }
    Ok((
        parse(&decode_canonical(parts[0])?)?,
        parse(&decode_canonical(parts[1])?)?,
    ))
}

pub(crate) fn acceptable_header(header: &Value) -> bool {
    header.is_object()
        && !["crit", "enc", "zip", "jku", "x5u", "x5c", "b64", "cty"]
            .iter()
            .any(|name| header.get(*name).is_some())
}

pub(crate) fn public_key_only(key: &Value) -> bool {
    key.is_object()
        && !["d", "p", "q", "dp", "dq", "qi", "oth", "k", "x5u", "jku"]
            .iter()
            .any(|name| key.get(*name).is_some())
}
