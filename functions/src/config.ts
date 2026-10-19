import { defineSecret } from "firebase-functions/params";

/**
 * Transit API keys. They exist only here, in Secret Manager: no build of the app holds one.
 *
 * Each agency in `agencies.ts` names its secret by `secretName`; the secret must also be listed in
 * `SECRETS` so the function is granted access to it at deploy time.
 *
 * Set with (value from the Keychain, never typed or echoed):
 *   security find-generic-password -a busbus -s "BusBus API key: mta-bustime-nyc" -w \
 *     | npx firebase-tools functions:secrets:set MTA_BUSTIME_KEY --project busbus-ios --data-file -
 */
export const mtaBusTimeKey = defineSecret("MTA_BUSTIME_KEY");

export const obaPugetSoundKey = defineSecret("OBA_PUGETSOUND_KEY");

export const obaTampaKey = defineSecret("OBA_TAMPA_KEY");

export const mobiliteitLuKey = defineSecret("MOBILITEIT_LU_KEY");

export const vbbKey = defineSecret("VBB_KEY");

export const SECRETS = [mtaBusTimeKey, obaPugetSoundKey, obaTampaKey, mobiliteitLuKey, vbbKey];
