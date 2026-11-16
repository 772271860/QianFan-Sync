<template>
  <div class="taobao-guanghe-image-publish-panel">
    <div v-if="accountId && hasAccountOverride(accountId)" style="margin-bottom: 12px;">
      <el-button size="small" @click="resetOverride">恢复为渠道默认</el-button>
    </div>

    <div class="setting-card" style="grid-column: 1 / -1">
      <div class="setting-label">图文标题 <span class="required">*</span></div>
      <el-input v-model="form.title" placeholder="加个标题让内容更吸引人" maxlength="30" show-word-limit :disabled="disabled" />
    </div>

    <div class="setting-card" style="grid-column: 1 / -1">
      <div class="setting-label">图文描述</div>
      <el-input v-model="form.description" type="textarea" :rows="5" placeholder="请输入描述..." maxlength="1000" show-word-limit :disabled="disabled" />
    </div>

    <div class="setting-card" style="grid-column: 1 / -1">
      <div class="setting-label">标签</div>
      <div class="setting-hint">输入话题内容,按回车确认(发布时拼成 #话题1 #话题2)</div>
      <el-input v-model="tagInput" placeholder="输入话题内容,按回车添加" @keyup.enter="addTag" clearable :disabled="disabled" />
      <div v-if="form.tags && form.tags.length > 0" class="tags-list">
        <el-tag v-for="(tag, index) in form.tags" :key="index" closable @close="removeTag(index)" size="small" :disable-transitions="false">#{{ tag }}</el-tag>
      </div>
    </div>

    <div class="setting-card" style="grid-column: 1 / -1">
      <div class="setting-label">创作者声明 <span class="required">*</span></div>
      <el-select v-model="form.guangheClaim" placeholder="请选择创作者声明" :disabled="disabled" style="width: 100%;">
        <el-option v-for="opt in claimOptions" :key="opt.value" :label="opt.label" :value="opt.value" />
      </el-select>
    </div>

    <div class="setting-card" style="grid-column: 1 / -1">
      <div class="setting-label">参与话题活动</div>
      <div class="setting-hint">由官方发起的征稿话题，参与有机会获得额外流量奖励（可选）</div>
      <RemoteSearchSelect
        v-model="form.guangheActivity"
        :data="form.guangheActivityData"
        :fetcher="fetchActivities"
        :field-map="{ label: 'name', desc: 'category' }"
        search-mode="frontend"
        empty-behavior="load-all"
        placeholder="选择话题活动（可搜索）"
        @change="handleActivityChange"
      />
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'
import { ElMessage } from 'element-plus'
import { useAccountStore } from '@/stores/account'
import { imagePublishApi } from '@/api/imagePublish'
import { guangheApi } from '@/api/taobaoGuanghe'
import { PLATFORMS } from '@/config/platforms'
import { useChannelForm } from '@/composables/useChannelForm'
import { useAutoExtractHashtags } from '@/utils/hashtag'
import RemoteSearchSelect from '@/components/common/RemoteSearchSelect.vue'

const props = defineProps({
  accountId: { type: [Number, Object], default: null },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(['config-changed', 'publish-result'])

const accountStore = useAccountStore()

// 创作者声明 options 复用平台配置
const claimField = PLATFORMS.TAOBAO_GUANGHE.settingsFields.find(f => f.key === 'guangheClaim')
const claimOptions = computed(() => claimField?.options || [])

const GUANGHE_IMAGE_DEFAULTS = {
  title: '',
  description: '',
  tags: [],
  guangheClaim: '内容无需标注',
  guangheActivity: '',
  guangheActivityData: null,
}

const { form, hasAccountOverride, resetOverride, publicApi } = useChannelForm(
  GUANGHE_IMAGE_DEFAULTS,
  { props, emit },
  {
    publishFn: async (accountId, accountName, commonData, merged, extra) => {
      const account = accountStore.accounts.find(a => a.id === accountId)
      if (!account) {
        emit('publish-result', { accountName, status: 'fail', message: '账号不存在' })
        return
      }
      try {
        await imagePublishApi.publishImage({
          image_ids: commonData.images.map(img => img.id),
          account_configs: {
            account_id: accountId,
            platform: '淘宝光合',
            filePath: account.filePath,
            title: merged.title,
            description: merged.description,
            tags: merged.tags || [],
            guangheClaim: merged.guangheClaim || '',
            activities: merged.guangheActivity ? [merged.guangheActivity] : [],
            cover_path: '',
            dry_run: false,
          },
          batchId: extra?.batchId || '',
          landscapeCoverMaterialId: '',
          portraitCoverMaterialId: '',
        })
        emit('publish-result', { accountName, status: 'success', message: '发布成功' })
      } catch (e) {
        emit('publish-result', { accountName, status: 'fail', message: e.message || '发布失败' })
      }
    },
    validateFn: (accountId, merged) => {
      const errors = []
      if (!merged.title || !merged.title.trim()) {
        errors.push('请填写图文标题(≤30 字)')
      }
      return { valid: errors.length === 0, errors }
    },
  },
)

const tagInput = ref('')

function addTag() {
  const tag = tagInput.value.trim()
  if (!tag) return
  if (!form.tags) form.tags = []
  if (form.tags.includes(tag)) { ElMessage.warning('话题已存在'); return }
  form.tags.push(tag)
  tagInput.value = ''
}

function removeTag(index) { form.tags.splice(index, 1) }

// 参与话题活动数据源（后端浏览器抓取 + TTL 缓存）
async function fetchActivities(keyword) {
  // 仅点开平台分组未选具体账号时，回退到第一个淘宝光合账号
  const accId = props.accountId ?? accountStore.accounts.find(a => a.platform === '淘宝光合')?.id
  const resp = await guangheApi.getActivityList(accId)
  const all = resp.data?.list || []
  const kw = keyword?.trim().toLowerCase()
  return {
    list: kw ? all.filter(it => it.name?.toLowerCase().includes(kw)) : all,
  }
}

function handleActivityChange(topic) {
  form.guangheActivityData = topic || null
}

// 自动提取描述中的 #xxx 到标签数组
useAutoExtractHashtags({
  form,
  descKey: 'description',
  tagKey: 'tags',
})

defineExpose(publicApi)
</script>

<style scoped lang="scss">
@use '@/styles/variables.scss' as *;

.taobao-guanghe-image-publish-panel {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
  gap: 12px;
}

.setting-card {
  border: 1px solid rgba($info-color, 0.15);
  background: rgba($info-color, 0.04);
  border-radius: 8px;
  padding: 16px;
}

.setting-label {
  font-size: 13px;
  font-weight: 600;
  color: #ff5000;
  margin-bottom: 8px;
}

.required {
  color: #f56c6c;
}

.setting-hint {
  font-size: 12px;
  color: #909399;
  margin-bottom: 8px;
  line-height: 1.5;
}

.tags-list {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}
</style>
