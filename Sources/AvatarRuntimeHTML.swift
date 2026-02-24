import Foundation

enum AvatarRuntimeHTML {
    static func makeHTML(baseURL: String) -> String {
        """
<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" />
  <style>
    html, body, canvas { margin:0; width:100%; height:100%; background: transparent; overflow: hidden; }
  </style>
  <script type=\"importmap\">
  {
    \"imports\": {
      \"three\": \"\(baseURL)/node_modules/three/build/three.module.js\",
      \"three/addons/\": \"\(baseURL)/node_modules/three/examples/jsm/\",
      \"@pixiv/three-vrm\": \"\(baseURL)/node_modules/@pixiv/three-vrm/lib/three-vrm.module.js\"
    }
  }
  </script>
</head>
<body>
<script type=\"module\">
let THREE = null;
let FBXLoader = null;
let GLTFLoader = null;
let VRMLoaderPlugin = null;
let VRMUtils = null;
let SkeletonUtils = null;

let scene = null;
let camera = null;
let renderer = null;
let controls = null;

let assetRoot = '';
let avatar = null; // for VRM, this is vrm.scene
let vrm = null;
let mixer = null;
let activeAction = null;
const actions = new Map();
let loader = null;
let gltfLoader = null;
let clock = null;
let calibrationProfile = null;
let avatarProfile = null;

const clipFiles = {
  greeting: 'animations/greeting.fbx',
  idle: 'animations/idle.fbx',
  idleYawn: 'animations/idle_yawn.fbx',
  looking: 'animations/looking.fbx',
  lookingDeep: 'animations/looking_deep.fbx',
  talking1: 'animations/talking_1.fbx',
  talking2: 'animations/talking_2.fbx',
  talking3: 'animations/talking_3.fbx'
};

function sendStatus(t) {
  try { window.webkit?.messageHandlers?.avatarStatus?.postMessage(t); } catch {}
}

function sendStage(step, text) {
  sendStatus(`avatar: [${step}] ${text}`);
}

window.avatarSetProfileJSON = (jsonText) => {
  const text = String(jsonText || '').trim();
  if (!text) {
    avatarProfile = null;
    sendStatus('avatar: profile cleared');
    return;
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === 'object' && parsed.mixamoToTarget && typeof parsed.mixamoToTarget === 'object') {
      avatarProfile = parsed;
      sendStatus(`avatar: profile injected (keys=${Object.keys(parsed.mixamoToTarget).length})`);
    } else {
      avatarProfile = null;
      sendStatus('avatar: profile injected but invalid');
    }
  } catch (err) {
    avatarProfile = null;
    sendStatus(`avatar: profile parse failed (${String(err)})`);
  }
};

window.addEventListener('error', (e) => {
  sendStatus(`avatar: js error (${e.message || 'unknown'})`);
});
window.addEventListener('unhandledrejection', (e) => {
  sendStatus(`avatar: js reject (${String(e.reason || 'unknown')})`);
});

function resize() {
  if (!camera || !renderer) return;
  const w = window.innerWidth || 1;
  const h = window.innerHeight || 1;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h, false);
}

function animate() {
  requestAnimationFrame(animate);
  if (!renderer || !scene || !camera || !clock) return;
  const dt = clock.getDelta();
  if (mixer) mixer.update(dt);
  if (vrm && typeof vrm.update === 'function') vrm.update(dt);
  if (controls) controls.update();
  renderer.render(scene, camera);
}

async function loadFBX(url) {
  if (!loader) throw new Error('loader not ready');
  return await loader.loadAsync(url);
}

function pickBestClip(animations) {
  const list = Array.isArray(animations) ? animations : [];
  let best = null;
  for (const c of list) {
    if (!c || !Array.isArray(c.tracks)) continue;
    if (!best || c.tracks.length > best.tracks.length) best = c;
  }
  return best;
}

async function loadVRM(url) {
  if (!gltfLoader) throw new Error('gltf loader not ready');
  const gltf = await gltfLoader.loadAsync(url);
  if (!gltf.userData || !gltf.userData.vrm) throw new Error('vrm extension not found');
  return gltf.userData.vrm;
}

async function loadAvatarProfile(url) {
  try {
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) return null;
    const json = await response.json();
    if (!json || typeof json !== 'object') return null;
    if (!json.mixamoToTarget || typeof json.mixamoToTarget !== 'object') return null;
    return json;
  } catch {
    return null;
  }
}

function clearSceneAvatar() {
  if (!avatar) return;
  scene.remove(avatar);
  avatar.traverse((obj) => {
    if (obj.isMesh) {
      obj.geometry?.dispose?.();
      if (Array.isArray(obj.material)) obj.material.forEach(m => m?.dispose?.());
      else obj.material?.dispose?.();
    }
  });
  avatar = null;
}

function tuneAvatarMeshRendering(root) {
  if (!root || !renderer || !THREE) return;
  let meshCount = 0;
  let materialCount = 0;
  let mapCount = 0;
  let normalMapCount = 0;
  const typeCounts = {};
  const applyMaterial = (mat) => {
    if (!mat) return;
    materialCount += 1;
    const typeName = String(mat.type || 'Unknown');
    typeCounts[typeName] = (typeCounts[typeName] || 0) + 1;
    if ('map' in mat && mat.map) mapCount += 1;
    if ('normalMap' in mat && mat.normalMap) normalMapCount += 1;
  };

  root.traverse((obj) => {
    if (!obj || !obj.isMesh) return;
    meshCount += 1;
    obj.frustumCulled = false;
    obj.renderOrder = obj.renderOrder || 0;
    if (Array.isArray(obj.material)) obj.material.forEach(applyMaterial);
    else applyMaterial(obj.material);
  });
  sendStatus(`avatar: material stats mesh=${meshCount}, mat=${materialCount}, map=${mapCount}, nrm=${normalMapCount}`);
  sendStatus(`avatar: material types ${Object.entries(typeCounts).map(([k, v]) => `${k}=${v}`).join(', ')}`);
}

function logTargetBoneSamples(targetSkinnedMesh) {
  const bones = (targetSkinnedMesh?.skeleton?.bones || []).map((b) => b.name);
  if (bones.length === 0) {
    sendStatus('avatar: target bones sample (none)');
    return;
  }
  const chunkSize = 8;
  for (let i = 0; i < bones.length; i += chunkSize) {
    const part = bones.slice(i, i + chunkSize).join(' | ');
    sendStatus(`avatar: target bones[${i}-${Math.min(i + chunkSize - 1, bones.length - 1)}] ${part}`);
  }
}


async function loadAvatarAndAnimations() {
  if (!assetRoot) {
    sendStatus('avatar: asset root empty');
    return;
  }
  if (!loader || !THREE) {
    sendStatus('avatar: loader not initialized');
    return;
  }

  let baseRoot = String(assetRoot || '');
  while (baseRoot.endsWith('/')) baseRoot = baseRoot.slice(0, -1);
  const baseURL = `${baseRoot}/avatars/default.fbx`;
  if (!avatarProfile) {
    avatarProfile = await loadAvatarProfile(`${assetRoot}/avatars/avatar_profile.json`);
    if (avatarProfile) {
      sendStatus(`avatar: profile loaded (keys=${Object.keys(avatarProfile.mixamoToTarget || {}).length})`);
    } else {
      sendStatus('avatar: profile not found (using auto map)');
    }
  } else {
    sendStatus(`avatar: profile active (keys=${Object.keys(avatarProfile.mixamoToTarget || {}).length})`);
  }
  sendStage('01', 'loading FBX base');
  clearSceneAvatar();
  let loadedBase = null;
  try {
    vrm = null;
    loadedBase = await loadFBX(baseURL);
    const summary = summarizeRig(loadedBase);
    sendStatus(`avatar: base probe ${baseURL} (mesh=${summary.meshCount}, skinned=${summary.skinnedCount}, bones=${summary.boneCount})`);
    if (!findFirstSkinnedMesh(loadedBase)) {
      throw new Error(`default.fbx has no skinned mesh (mesh=${summary.meshCount}, skinned=${summary.skinnedCount}, bones=${summary.boneCount})`);
    }
    sendStatus('avatar: base loaded (default.fbx)');
  } catch (err) {
    sendStatus(`avatar: base load failed (${String(err)})`);
    return;
  }

  avatar = loadedBase;
  avatar.position.set(0, 0, 0);
  avatar.rotation.set(0, 0, 0);
  sendStatus('avatar: facing forced 0');
  tuneAvatarMeshRendering(avatar);
  scene.add(avatar);

  const box = new THREE.Box3().setFromObject(avatar);
  const center = box.getCenter(new THREE.Vector3());
  avatar.position.sub(center);

  // Normalize to floor after centering, then recompute bounds for camera framing.
  const groundedBox = new THREE.Box3().setFromObject(avatar);
  avatar.position.y -= groundedBox.min.y;
  const finalBox = new THREE.Box3().setFromObject(avatar);
  const size = finalBox.getSize(new THREE.Vector3());
  const dist = Math.max(3.6, size.y * 2.1);
  camera.near = 0.01;
  camera.far = Math.max(1000, size.y * 60);
  camera.position.set(0, size.y * 0.82, dist);
  camera.lookAt(0, size.y * 0.5, 0);
  camera.updateProjectionMatrix();
  if (controls) {
    controls.target.set(0, size.y * 0.5, 0);
    controls.minDistance = Math.max(1.2, size.y * 0.6);
    controls.maxDistance = Math.max(60.0, size.y * 30.0);
    controls.update();
  }

  const targetSkinnedMesh = findFirstSkinnedMesh(avatar);
  if (!targetSkinnedMesh) {
    sendStatus('avatar: no skinned mesh in base fbx');
    return;
  }

  mixer = new THREE.AnimationMixer(avatar);
  mixer.timeScale = 1.0;
  actions.clear();
  let totalTracks = 0;
  let totalMappedBones = 0;

  sendStage('02', 'building bone map');
  calibrationProfile = buildCalibrationProfile(null, null, null, targetSkinnedMesh);
  if (!calibrationProfile || !calibrationProfile.targetToMixBone || Object.keys(calibrationProfile.targetToMixBone).length === 0) {
    sendStatus('avatar: bone map missing');
  } else {
    sendStatus(
      `avatar: bone map ready bones=${Object.keys(calibrationProfile.targetToMixBone).length}`
    );
  }
  sendStatus(`avatar: target skeleton bones=${targetSkinnedMesh.skeleton?.bones?.length || 0}`);
  logMappingDiagnostics(calibrationProfile, targetSkinnedMesh);
  logTargetBoneSamples(targetSkinnedMesh);

  sendStage('03', 'retargeting clips');
  for (const [name, rel] of Object.entries(clipFiles)) {
    try {
      const clipSource = await loadFBX(`${assetRoot}/${rel}`);
      const clip = pickBestClip(clipSource.animations);
      if (!clip) {
        sendStatus(`avatar: clip missing anim ${name}`);
        continue;
      }
      sendStatus(`avatar: clip info ${name} (tracks=${clip.tracks?.length || 0}, duration=${Number(clip.duration || 0).toFixed(3)})`);
      const sameRig = remapClipTracksSameRig(clip, targetSkinnedMesh, calibrationProfile);
      if (sameRig && sameRig.tracks.length > 0) {
        sendStatus(`avatar: same-rig map ok ${name} (tracks=${sameRig.tracks.length})`);
        const action = mixer.clipAction(sameRig);
        actions.set(name, action);
        totalTracks += sameRig.tracks.length;
        continue;
      }
      const mapped = Object.keys(calibrationProfile?.targetToMixBone || {}).length;
      sendStatus(`avatar: same-rig map fail ${name} (tracks=0, calMap=${mapped})`);
    } catch (err) {
      sendStatus(`avatar: clip load fail ${name} (${String(err)})`);
    }
  }

  sendStatus(`avatar: loaded clips=${actions.size} tracks=${totalTracks} bones=${totalMappedBones}`);
  if (!actions.has('idle') && actions.has('idleYawn')) {
    actions.set('idle', actions.get('idleYawn'));
    sendStatus('avatar: idle fallback -> idleYawn');
  }
  sendStage('04', 'starting idle');
  playMotion('idle');
  sendStatus(`avatar: playing idle=${actions.has('idle') ? 'yes' : 'no'}`);
}

function playMotion(name) {
  if (!mixer || actions.size === 0) return;
  const next = actions.get(name) || actions.get('idle');
  if (!next) return;

  const loop = (name === 'idle' || name === 'looking' || name === 'lookingDeep');
  next.reset();
  next.enabled = true;
  next.setLoop(loop ? THREE.LoopRepeat : THREE.LoopOnce, loop ? Infinity : 1);
  next.clampWhenFinished = !loop;

  if (activeAction && activeAction !== next) {
    activeAction.crossFadeTo(next, 0.18, true);
  }
  next.play();
  activeAction = next;

  if (!loop) {
    const done = (e) => {
      if (e.action === next) {
        mixer.removeEventListener('finished', done);
        playMotion('idle');
      }
    };
    mixer.addEventListener('finished', done);
  }
}

function findSourceBoneNode(root, mixBoneName) {
  if (!root) return null;
  const base = String(mixBoneName || '').replace(/^mixamorig:?/i, '');
  if (root.skeleton && Array.isArray(root.skeleton.bones)) {
    const fromSkeleton = root.skeleton.bones.find((b) =>
      b.name === `mixamorig:${base}` || b.name === `mixamorig${base}` || b.name === base
    );
    if (fromSkeleton) return fromSkeleton;
  }
  return (
    root.getObjectByName(`mixamorig:${base}`) ||
    root.getObjectByName(`mixamorig${base}`) ||
    root.getObjectByName(base) ||
    root.getObjectByProperty('name', base)
  );
}

function findFirstSkinnedMesh(root) {
  let found = null;
  root.traverse((obj) => {
    if (found) return;
    if (obj && obj.isSkinnedMesh && obj.skeleton && obj.skeleton.bones && obj.skeleton.bones.length > 0) {
      found = obj;
    }
  });
  return found;
}

function summarizeRig(root) {
  let meshCount = 0;
  let skinnedCount = 0;
  let boneCount = 0;
  if (!root) return { meshCount, skinnedCount, boneCount };
  root.traverse((obj) => {
    if (!obj) return;
    if (obj.isMesh) meshCount += 1;
    if (obj.isSkinnedMesh) {
      skinnedCount += 1;
      boneCount += obj.skeleton?.bones?.length || 0;
    }
  });
  return { meshCount, skinnedCount, boneCount };
}

function findBoneInSkeletonByName(skeleton, name) {
  if (!skeleton || !Array.isArray(skeleton.bones) || !name) return null;
  return skeleton.bones.find((b) => b.name === name) || null;
}

function detectSourceBoneName(sourceRig, mixBoneName) {
  if (!sourceRig) return null;
  const candidates = [
    `mixamorig:${mixBoneName}`,
    `mixamorig${mixBoneName}`,
    mixBoneName
  ];
  for (const c of candidates) {
    if (findSourceBoneNode(sourceRig, c) || sourceRig?.getObjectByName?.(c)) {
      return c;
    }
  }
  return null;
}

function getMixamoToVRMBoneMap() {
  return {
    Hips: 'hips',
    Spine: 'spine',
    Spine1: 'chest',
    Spine2: 'upperChest',
    Neck: 'neck',
    Head: 'head',
    LeftShoulder: 'leftShoulder',
    LeftArm: 'leftUpperArm',
    LeftForeArm: 'leftLowerArm',
    LeftHand: 'leftHand',
    RightShoulder: 'rightShoulder',
    RightArm: 'rightUpperArm',
    RightForeArm: 'rightLowerArm',
    RightHand: 'rightHand',
    LeftUpLeg: 'leftUpperLeg',
    LeftLeg: 'leftLowerLeg',
    LeftFoot: 'leftFoot',
    LeftToeBase: 'leftToes',
    RightUpLeg: 'rightUpperLeg',
    RightLeg: 'rightLowerLeg',
    RightFoot: 'rightFoot',
    RightToeBase: 'rightToes'
  };
}

function buildHumanBoneNameByTargetBoneName(vrmModel) {
  const out = {};
  if (!vrmModel || !vrmModel.humanoid) return out;
  const humanoid = vrmModel.humanoid;
  const map = getMixamoToVRMBoneMap();
  for (const [mixBone, vrmBone] of Object.entries(map)) {
    const node =
      humanoid.getRawBoneNode?.(vrmBone) ||
      humanoid.getNormalizedBoneNode?.(vrmBone);
    if (node && node.name) out[node.name] = mixBone;
  }
  return out;
}

function buildTargetToMixBoneKeyMap(vrmModel, targetSkinnedMesh) {
  if (!targetSkinnedMesh || !targetSkinnedMesh.skeleton) return {};
  if (avatarProfile && avatarProfile.mixamoToTarget) {
    const targetToMix = {};
    let valid = 0;
    const validTargetBones = new Set((targetSkinnedMesh.skeleton?.bones || []).map((b) => b.name));
    for (const [mixBone, targetBone] of Object.entries(avatarProfile.mixamoToTarget)) {
      if (!targetBone) continue;
      if (!validTargetBones.has(targetBone)) continue;
      targetToMix[targetBone] = mixBone;
      valid += 1;
    }
    sendStatus(`avatar: profile map applied=${valid}`);
    if (valid === 0) {
      sendStatus('avatar: profile map has zero valid target bone names');
    }
    if (Object.keys(targetToMix).length > 0) {
      return targetToMix;
    }
  }
  const byHumanName = buildHumanBoneNameByTargetBoneName(vrmModel);
  const targetToMixBone = {};
  for (const bone of targetSkinnedMesh.skeleton.bones || []) {
    const normalized = normalizeMixBoneKey(bone.name);
    if (normalized) {
      targetToMixBone[bone.name] = normalized;
      continue;
    }

    const direct = byHumanName[bone.name];
    if (direct) {
      targetToMixBone[bone.name] = direct;
      continue;
    }

    const n = String(bone.name || '').toLowerCase();
    if (n.includes('hip')) targetToMixBone[bone.name] = 'Hips';
    else if (n.includes('spine2') || (n.includes('spine') && n.includes('upper'))) targetToMixBone[bone.name] = 'Spine2';
    else if (n.includes('spine1') || (n.includes('spine') && n.includes('chest'))) targetToMixBone[bone.name] = 'Spine1';
    else if (n.includes('spine')) targetToMixBone[bone.name] = 'Spine';
    else if (n.includes('neck')) targetToMixBone[bone.name] = 'Neck';
    else if (n.includes('head')) targetToMixBone[bone.name] = 'Head';
    else if (n.includes('left') && n.includes('shoulder')) targetToMixBone[bone.name] = 'LeftShoulder';
    else if (n.includes('right') && n.includes('shoulder')) targetToMixBone[bone.name] = 'RightShoulder';
    else if (n.includes('left') && (n.includes('forearm') || n.includes('lowerarm'))) targetToMixBone[bone.name] = 'LeftForeArm';
    else if (n.includes('right') && (n.includes('forearm') || n.includes('lowerarm'))) targetToMixBone[bone.name] = 'RightForeArm';
    else if (n.includes('left') && (n.includes('upperarm') || n.includes('uparm'))) targetToMixBone[bone.name] = 'LeftArm';
    else if (n.includes('right') && (n.includes('upperarm') || n.includes('uparm'))) targetToMixBone[bone.name] = 'RightArm';
    else if (n.includes('left') && n.includes('hand')) targetToMixBone[bone.name] = 'LeftHand';
    else if (n.includes('right') && n.includes('hand')) targetToMixBone[bone.name] = 'RightHand';
    else if (n.includes('left') && (n.includes('upleg') || n.includes('thigh') || n.includes('upperleg'))) targetToMixBone[bone.name] = 'LeftUpLeg';
    else if (n.includes('right') && (n.includes('upleg') || n.includes('thigh') || n.includes('upperleg'))) targetToMixBone[bone.name] = 'RightUpLeg';
    else if (n.includes('left') && (n.includes('lowerleg') || n.includes('calf'))) targetToMixBone[bone.name] = 'LeftLeg';
    else if (n.includes('right') && (n.includes('lowerleg') || n.includes('calf'))) targetToMixBone[bone.name] = 'RightLeg';
    else if (n.includes('left') && n.includes('foot')) targetToMixBone[bone.name] = 'LeftFoot';
    else if (n.includes('right') && n.includes('foot')) targetToMixBone[bone.name] = 'RightFoot';
    else if (n.includes('left') && n.includes('toe')) targetToMixBone[bone.name] = 'LeftToeBase';
    else if (n.includes('right') && n.includes('toe')) targetToMixBone[bone.name] = 'RightToeBase';
  }
  return targetToMixBone;
}

function isAncestorBone(skeleton, maybeAncestorName, boneName) {
  if (!skeleton || !maybeAncestorName || !boneName) return false;
  const byName = new Map((skeleton.bones || []).map((b) => [b.name, b]));
  let cur = byName.get(boneName);
  const target = byName.get(maybeAncestorName);
  if (!cur || !target) return false;
  while (cur && cur.parent) {
    if (cur.parent === target) return true;
    cur = cur.parent;
  }
  return false;
}

function logMappingDiagnostics(calibrationProfile, targetSkinnedMesh) {
  const targetToMix = calibrationProfile?.targetToMixBone || {};
  const mixToTarget = {};
  for (const [target, mix] of Object.entries(targetToMix)) {
    mixToTarget[mix] = target;
  }
  const keys = Object.keys(mixToTarget).sort();
  if (keys.length > 0) {
    const text = keys.map((k) => `${k}->${mixToTarget[k]}`).join(' | ');
    sendStatus(`avatar: map active ${text}`);
  }

  const skeleton = targetSkinnedMesh?.skeleton;
  const chainChecks = [
    ['LeftShoulder', 'LeftArm'],
    ['LeftArm', 'LeftForeArm'],
    ['LeftForeArm', 'LeftHand'],
    ['RightShoulder', 'RightArm'],
    ['RightArm', 'RightForeArm'],
    ['RightForeArm', 'RightHand'],
    ['LeftUpLeg', 'LeftLeg'],
    ['LeftLeg', 'LeftFoot'],
    ['LeftFoot', 'LeftToeBase'],
    ['RightUpLeg', 'RightLeg'],
    ['RightLeg', 'RightFoot'],
    ['RightFoot', 'RightToeBase']
  ];
  for (const [pMix, cMix] of chainChecks) {
    const p = mixToTarget[pMix];
    const c = mixToTarget[cMix];
    if (!p || !c) continue;
    if (!isAncestorBone(skeleton, p, c)) {
      sendStatus(`avatar: map warning chain mismatch ${pMix}->${cMix} (${p} !> ${c})`);
    }
  }
}

function buildCalibrationProfile(vrmModel, calibrationRig, calibrationMeshRig, targetSkinnedMesh) {
  const mapSource = calibrationRig || calibrationMeshRig || null;
  const meshSource = calibrationMeshRig || calibrationRig || null;
  const targetToMixBone = buildTargetToMixBoneKeyMap(vrmModel, targetSkinnedMesh);
  const probeSource = meshSource || mapSource;
  let resolvedCount = 0;
  const sourceNameByTarget = {};
  const offsetQuatByTarget = {};
  const sourceBoneNameByMix = {};
  const sourceParentByBone = {};
  const targetParentByBone = {};
  const sourceRestLocal = {};
  const sourceRestWorld = {};
  const targetRestLocal = {};
  const targetRestWorld = {};
  if (probeSource) {
    for (const mixBone of Object.values(targetToMixBone)) {
      if (detectSourceBoneName(probeSource, mixBone)) resolvedCount += 1;
    }
  }
  const sourceSkinnedMesh = (meshSource ? findFirstSkinnedMesh(meshSource) : null) || targetSkinnedMesh || null;
  const hipName = sourceSkinnedMesh
    ? (detectSourceBoneName(sourceSkinnedMesh, 'Hips') || 'mixamorig:Hips')
    : 'mixamorig:Hips';
  if (sourceSkinnedMesh?.skeleton) {
    sourceSkinnedMesh.skeleton.pose();
    sourceSkinnedMesh.updateMatrixWorld(true);
    for (const bone of sourceSkinnedMesh.skeleton.bones || []) {
      sourceParentByBone[bone.name] = bone.parent?.isBone ? bone.parent.name : null;
      sourceRestLocal[bone.name] = [bone.quaternion.x, bone.quaternion.y, bone.quaternion.z, bone.quaternion.w];
    }
  }
  if (targetSkinnedMesh?.skeleton) {
    targetSkinnedMesh.skeleton.pose();
    targetSkinnedMesh.updateMatrixWorld(true);
    for (const bone of targetSkinnedMesh.skeleton.bones || []) {
      targetParentByBone[bone.name] = bone.parent?.isBone ? bone.parent.name : null;
      targetRestLocal[bone.name] = [bone.quaternion.x, bone.quaternion.y, bone.quaternion.z, bone.quaternion.w];
    }
  }

  // Build source bone names per Mixamo key using calibration source.
  for (const mixBone of Object.values(targetToMixBone)) {
    const sourceBoneName = detectSourceBoneName(mapSource || sourceSkinnedMesh, mixBone);
    if (sourceBoneName) sourceBoneNameByMix[mixBone] = sourceBoneName;
  }

  // World rest quaternions for source skeleton.
  const qIdentity = new THREE.Quaternion();
  const sourceWorldCache = {};
  function getSourceRestWorldQuat(name, visiting = new Set()) {
    if (!name) return qIdentity.clone();
    if (sourceWorldCache[name]) return sourceWorldCache[name].clone();
    if (visiting.has(name)) return qIdentity.clone();
    visiting.add(name);
    const localArr = sourceRestLocal[name];
    if (!localArr) return qIdentity.clone();
    const local = new THREE.Quaternion(localArr[0], localArr[1], localArr[2], localArr[3]).normalize();
    const parent = sourceParentByBone[name];
    const world = parent ? getSourceRestWorldQuat(parent, visiting).multiply(local) : local.clone();
    sourceWorldCache[name] = world.clone();
    sourceRestWorld[name] = [world.x, world.y, world.z, world.w];
    visiting.delete(name);
    return world.clone();
  }
  Object.keys(sourceRestLocal).forEach((n) => { getSourceRestWorldQuat(n); });

  // World rest quaternions for target skeleton.
  const targetWorldCache = {};
  function getTargetRestWorldQuat(name, visiting = new Set()) {
    if (!name) return qIdentity.clone();
    if (targetWorldCache[name]) return targetWorldCache[name].clone();
    if (visiting.has(name)) return qIdentity.clone();
    visiting.add(name);
    const localArr = targetRestLocal[name];
    if (!localArr) return qIdentity.clone();
    const local = new THREE.Quaternion(localArr[0], localArr[1], localArr[2], localArr[3]).normalize();
    const parent = targetParentByBone[name];
    const world = parent ? getTargetRestWorldQuat(parent, visiting).multiply(local) : local.clone();
    targetWorldCache[name] = world.clone();
    targetRestWorld[name] = [world.x, world.y, world.z, world.w];
    visiting.delete(name);
    return world.clone();
  }
  Object.keys(targetRestLocal).forEach((n) => { getTargetRestWorldQuat(n); });

  if (targetSkinnedMesh?.skeleton) {
    const sourceRef = mapSource || sourceSkinnedMesh || targetSkinnedMesh;
    for (const [targetBoneName, mixBone] of Object.entries(targetToMixBone)) {
      const sourceBoneName = detectSourceBoneName(sourceRef, mixBone);
      if (!sourceBoneName) continue;
      sourceNameByTarget[targetBoneName] = sourceBoneName;
    }
  }

  return {
    targetToMixBone,
    hipName,
    sourceSkinnedMesh,
    resolvedCount,
    sourceNameByTarget,
    offsetQuatByTarget,
    sourceBoneNameByMix,
    sourceParentByBone,
    targetParentByBone,
    sourceRestLocal,
    sourceRestWorld,
    targetRestLocal,
    targetRestWorld
  };
}

function buildResolvedNamesForSource(targetToMixBone, sourceReference) {
  const resolved = {};
  for (const [targetBoneName, mixBone] of Object.entries(targetToMixBone || {})) {
    const srcName = detectSourceBoneName(sourceReference, mixBone);
    if (!srcName) continue;
    resolved[targetBoneName] = srcName;
  }
  return resolved;
}

function resetTargetPose(targetSkinnedMesh) {
  if (!targetSkinnedMesh || !targetSkinnedMesh.skeleton) return;
  targetSkinnedMesh.skeleton.pose();
  targetSkinnedMesh.updateMatrixWorld(true);
}

function normalizeMixBoneKey(name) {
  const full = String(name || '');
  const pipeSplit = full.split('|');
  const afterPipe = pipeSplit.length > 0 ? pipeSplit[pipeSplit.length - 1] : full;
  const slashSplit = afterPipe.split('/');
  const afterSlash = slashSplit.length > 0 ? slashSplit[slashSplit.length - 1] : afterPipe;
  const backSplit = afterSlash.split('\\\\');
  const token = backSplit.length > 0 ? backSplit[backSplit.length - 1] : afterSlash;
  const raw = token.replace(/^mixamorig:?/i, '');
  const key = raw.replace(/[^a-z0-9]/gi, '').toLowerCase();
  const table = {
    hips: 'Hips',
    spine: 'Spine',
    spine1: 'Spine1',
    spine2: 'Spine2',
    chest: 'Spine1',
    upperchest: 'Spine2',
    neck: 'Neck',
    head: 'Head',
    leftshoulder: 'LeftShoulder',
    rightshoulder: 'RightShoulder',
    leftarm: 'LeftArm',
    rightarm: 'RightArm',
    leftforearm: 'LeftForeArm',
    rightforearm: 'RightForeArm',
    leftlowerarm: 'LeftForeArm',
    rightlowerarm: 'RightForeArm',
    leftupperarm: 'LeftArm',
    rightupperarm: 'RightArm',
    lefthand: 'LeftHand',
    righthand: 'RightHand',
    leftupleg: 'LeftUpLeg',
    rightupleg: 'RightUpLeg',
    leftthigh: 'LeftUpLeg',
    rightthigh: 'RightUpLeg',
    leftleg: 'LeftLeg',
    rightleg: 'RightLeg',
    leftlowerleg: 'LeftLeg',
    rightlowerleg: 'RightLeg',
    leftcalf: 'LeftLeg',
    rightcalf: 'RightLeg',
    leftfoot: 'LeftFoot',
    rightfoot: 'RightFoot',
    lefttoebase: 'LeftToeBase',
    righttoebase: 'RightToeBase',
    lefttoe: 'LeftToeBase',
    righttoe: 'RightToeBase'
  };
  return table[key] || null;
}

function parseTrackBoneAndProperty(trackName) {
  const text = String(trackName || '');

  const bonesToken = '.bones[';
  const bonesStart = text.indexOf(bonesToken);
  if (bonesStart >= 0) {
    const nameStart = bonesStart + bonesToken.length;
    const nameEnd = text.indexOf(']', nameStart);
    if (nameEnd > nameStart && nameEnd + 2 < text.length && text[nameEnd + 1] === '.') {
      const prop = text.slice(nameEnd + 2);
      if (prop === 'quaternion' || prop === 'position') {
        const bone = text.slice(nameStart, nameEnd);
        return { bone, property: prop };
      }
    }
  }

  const dot = text.lastIndexOf('.');
  if (dot > 0 && dot + 1 < text.length) {
    const prop = text.slice(dot + 1);
    if (prop === 'quaternion' || prop === 'position') {
      const bone = text.slice(0, dot);
      return { bone, property: prop };
    }
  }
  return null;
}

function remapClipTracksSameRig(clip, targetSkinnedMesh, calibrationProfile) {
  if (!clip || !Array.isArray(clip.tracks) || !targetSkinnedMesh?.skeleton) return null;
  const targetBones = targetSkinnedMesh.skeleton.bones || [];
  if (targetBones.length === 0) return null;

  const targetNameSet = new Set(targetBones.map((b) => b.name));
  const mixToTarget = {};
  for (const [target, mix] of Object.entries(calibrationProfile?.targetToMixBone || {})) {
    if (!mixToTarget[mix] && targetNameSet.has(target)) mixToTarget[mix] = target;
  }

  const outTracks = [];
  for (const track of clip.tracks) {
    const parsed = parseTrackBoneAndProperty(track.name);
    if (!parsed) continue;
    if (parsed.property !== 'quaternion' && parsed.property !== 'position') continue;

    let targetBoneName = null;
    if (targetNameSet.has(parsed.bone)) {
      targetBoneName = parsed.bone;
    } else {
      const key = normalizeMixBoneKey(parsed.bone);
      if (key && mixToTarget[key]) targetBoneName = mixToTarget[key];
    }
    if (!targetBoneName) continue;

    if (parsed.property === 'position') {
      const key = normalizeMixBoneKey(targetBoneName);
      if (key !== 'Hips') continue;
    }

    const cloned = track.clone();
    cloned.name = `${targetBoneName}.${parsed.property}`;
    outTracks.push(cloned);
  }

  if (outTracks.length === 0) return null;
  const out = new THREE.AnimationClip(`${clip.name || 'clip'}_sameRig`, clip.duration ?? -1, outTracks);
  out.userData = { mode: 'same-rig' };
  return out;
}

function remapClipTracksDirect(clip, calibrationProfile, targetSkinnedMesh) {
  const targetToMixBone = calibrationProfile?.targetToMixBone || {};
  if (!clip || !Array.isArray(clip.tracks) || !targetToMixBone) return null;
  const targetBones = (targetSkinnedMesh?.skeleton?.bones || []).map((b) => b.name);
  if (targetBones.length === 0) return null;

  // Source animation quaternion tracks by Mixamo key.
  const trackByMix = {};
  for (const track of clip.tracks) {
    const parsed = parseTrackBoneAndProperty(track.name);
    if (!parsed || parsed.property !== 'quaternion') continue;
    const mixBone = normalizeMixBoneKey(parsed.bone);
    if (!mixBone) continue;
    if (!trackByMix[mixBone]) trackByMix[mixBone] = track;
  }

  // Time base from hips or any quaternion track.
  const anyTrack = trackByMix.Hips || Object.values(trackByMix)[0];
  if (!anyTrack || !anyTrack.times || anyTrack.times.length === 0) return null;
  const times = anyTrack.times.slice(0);
  const frameCount = times.length;

  const sourceBoneNameByMix = calibrationProfile?.sourceBoneNameByMix || {};
  const sourceRestLocal = calibrationProfile?.sourceRestLocal || {};
  const targetRestLocal = calibrationProfile?.targetRestLocal || {};

  const sourceMixByBone = {};
  for (const [mix, bone] of Object.entries(sourceBoneNameByMix)) {
    sourceMixByBone[bone] = mix;
  }

  const validTargetSet = new Set(targetBones);
  const mappedTargets = [];
  for (const [targetBone, mixBone] of Object.entries(targetToMixBone)) {
    if (!validTargetSet.has(targetBone)) continue;
    const srcBone = sourceBoneNameByMix[mixBone];
    if (!srcBone) continue;
    mappedTargets.push({ targetBone, mixBone, srcBone });
  }
  if (mappedTargets.length === 0) return null;

  const qIdentity = new THREE.Quaternion();
  const toQuat = (arr) => arr && arr.length === 4
    ? new THREE.Quaternion(arr[0], arr[1], arr[2], arr[3]).normalize()
    : qIdentity.clone();

  function sampleSourceLocalQuat(sourceBoneName, frame) {
    const mix = sourceMixByBone[sourceBoneName];
    const tr = mix ? trackByMix[mix] : null;
    if (tr && tr.values && tr.values.length >= (frame + 1) * 4) {
      const i = frame * 4;
      return new THREE.Quaternion(tr.values[i], tr.values[i + 1], tr.values[i + 2], tr.values[i + 3]).normalize();
    }
    return toQuat(sourceRestLocal[sourceBoneName]);
  }

  const outTracks = [];
  for (const { targetBone, srcBone } of mappedTargets) {
    const srcRest = toQuat(sourceRestLocal[srcBone]);
    const tgtRest = toQuat(targetRestLocal[targetBone]);
    const srcRestInv = srcRest.clone().invert();
    const outValues = new Float32Array(frameCount * 4);

    for (let frame = 0; frame < frameCount; frame += 1) {
      const srcAnim = sampleSourceLocalQuat(srcBone, frame);
      const delta = srcRestInv.clone().multiply(srcAnim).normalize();
      const tgtLocal = tgtRest.clone().multiply(delta).normalize();

      const o = frame * 4;
      outValues[o] = tgtLocal.x;
      outValues[o + 1] = tgtLocal.y;
      outValues[o + 2] = tgtLocal.z;
      outValues[o + 3] = tgtLocal.w;
    }

    outTracks.push(new THREE.QuaternionKeyframeTrack(`${targetBone}.quaternion`, times, outValues));
  }

  if (outTracks.length === 0) return null;
  return new THREE.AnimationClip(`${clip.name || 'clip'}_retargeted`, -1, outTracks);
}

function retargetClipToVRM({ clip, calibration, targetSkinnedMesh }) {
  return remapClipTracksDirect(clip, calibration, targetSkinnedMesh);
}

window.avatarSetAssetRoot = (root) => {
  const v = String(root || '');
  assetRoot = v.endsWith('/') ? v.slice(0, -1) : v;
  loadAvatarAndAnimations();
};

window.avatarPlay = (motion) => {
  playMotion(String(motion || 'idle'));
};

window.avatarReload = () => {
  loadAvatarAndAnimations();
};

async function init() {
  sendStatus('avatar: module init');
  try {
    const threeMod = await import('three');
    const fbxMod = await import('three/addons/loaders/FBXLoader.js');
    const gltfMod = await import('three/addons/loaders/GLTFLoader.js');
    const skeletonUtilsMod = await import('three/addons/utils/SkeletonUtils.js');
    const vrmMod = await import('@pixiv/three-vrm');
    const controlsMod = await import('three/addons/controls/OrbitControls.js');
    THREE = threeMod;
    FBXLoader = fbxMod.FBXLoader;
    GLTFLoader = gltfMod.GLTFLoader;
    SkeletonUtils = skeletonUtilsMod;
    VRMLoaderPlugin = vrmMod.VRMLoaderPlugin;
    VRMUtils = vrmMod.VRMUtils;
    window.__OrbitControls = controlsMod.OrbitControls;
  } catch (err) {
    sendStatus(`avatar: module import failed (${String(err)})`);
    return;
  }

  scene = new THREE.Scene();
  scene.background = null;
  camera = new THREE.PerspectiveCamera(40, 1, 0.1, 300);
  camera.position.set(0, 1.55, 3.8);
  camera.lookAt(0, 1.2, 0);

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, logarithmicDepthBuffer: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  document.body.appendChild(renderer.domElement);

  scene.add(new THREE.HemisphereLight(0xffffff, 0x263238, 1.05));
  const key = new THREE.DirectionalLight(0xffffff, 1.25);
  key.position.set(2.0, 3.0, 2.0);
  scene.add(key);

  loader = new FBXLoader();
  gltfLoader = new GLTFLoader();
  gltfLoader.register((parser) => {
    return new VRMLoaderPlugin(parser);
  });
  controls = new window.__OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.dampingFactor = 0.08;
  controls.enablePan = true;
  controls.zoomSpeed = 0.9;
  controls.rotateSpeed = 0.8;
  controls.screenSpacePanning = true;
  controls.target.set(0, 1.0, 0);
  controls.minPolarAngle = 0.1;
  controls.maxPolarAngle = Math.PI - 0.1;
  controls.update();
  clock = new THREE.Clock();
  window.addEventListener('resize', resize);
  resize();
  animate();
  sendStatus('avatar: scene ready');
}

init();
</script>
</body>
</html>
"""
    }
}
